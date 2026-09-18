// lib/src/store.dart
/// In-memory consultation scheduling store.
///
/// Models the two core entities of the API contract:
///   - [Slot]   : a doctor-defined availability window with a fixed capacity.
///   - [Booking]: a single user registration for a specific slot.
///
/// Booking creation is serialized through an async mutex ([AsyncLock]) so the
/// "check capacity -> check duplicate -> insert" sequence is atomic even when
/// many clients race at the same time. Dart runs one isolate per VM, but HTTP
/// handlers are async; without a lock two concurrent `createBooking` calls
/// could both observe `remaining > 0` and over-book. The lock prevents that.
library;

import 'dart:async';

/// A "user visible" time window offered for consultation.
class Slot {
  Slot({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.capacity,
    this.adminNote,
  }) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'must be >= 1');
    }
    if (!endTime.isAfter(startTime)) {
      throw ArgumentError.value('endTime', 'endTime', 'must be after startTime');
    }
  }

  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final int capacity;
  final String? adminNote;

  int registrationCount(List<Booking> bookings) =>
      bookings.where((b) => b.slotId == id).length;

  /// Serializes a slot together with its live seat counters.
  Map<String, dynamic> toJson(List<Booking> bookings) {
    final taken = registrationCount(bookings);
    final remaining = (capacity - taken).clamp(0, capacity);
    return {
      'id': id,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime.toIso8601String(),
      'capacity': capacity,
      'adminNote': adminNote,
      'taken': taken,
      'remaining': remaining,
    };
  }

  factory Slot.fromJson(Map<String, dynamic> json) => Slot(
        id: json['id'] as String,
        startTime: DateTime.parse(json['startTime'] as String),
        endTime: DateTime.parse(json['endTime'] as String),
        capacity: json['capacity'] as int,
        adminNote: json['adminNote'] as String?,
      );
}

/// One registration made by a user for a [Slot].
class Booking {
  Booking({
    required this.bookingId,
    required this.slotId,
    required this.userId,
    required this.userName,
    required this.userEmail,
    required this.createdAt,
  });

  final String bookingId;
  final String slotId;
  final String userId;
  final String userName;
  final String userEmail;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'bookingId': bookingId,
        'slotId': slotId,
        'userId': userId,
        'userName': userName,
        'userEmail': userEmail,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Booking.fromJson(Map<String, dynamic> json) => Booking(
        bookingId: json['bookingId'] as String,
        slotId: json['slotId'] as String,
        userId: json['userId'] as String,
        userName: json['userName'] as String,
        userEmail: json['userEmail'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
/// Outcome of a booking attempt (sealed union).
sealed class BookingResult {
  const BookingResult();
}

/// The booking was created successfully.
class BookingCreated extends BookingResult {
  const BookingCreated(this.booking);
  final Booking booking;
}

/// The slot does not exist.
class BookingSlotNotFound extends BookingResult {
  const BookingSlotNotFound(this.slotId);
  final String slotId;
}

/// The slot is already full (capacity reached).
class BookingSlotFull extends BookingResult {
  const BookingSlotFull(this.slot);
  final Slot slot;
}

/// The user already booked the same slot.
class BookingDuplicate extends BookingResult {
  const BookingDuplicate();
}

/// Request payload was invalid (missing/blank fields).
class BookingInvalid extends BookingResult {
  const BookingInvalid(this.message);
  final String message;
}

/// Event emitted right after a booking is confirmed. Consumed by the SSE
/// realtime endpoint so admin clients refresh counts/lists immediately.
class BookingEvent {
  const BookingEvent(this.booking);
  final Booking booking;
}

/// A minimal async mutual-exclusion lock.
///
/// Futures are chained so that each critical section runs strictly after the
/// previous one completes. This turns the store's read-modify-write into a
/// transaction, satisfying the "atomic decrement/check capacity" requirement.
class AsyncLock {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronize<T>(Future<T> Function() action) {
    final previous = _tail;
    final next = Completer<void>();
    _tail = next.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        if (!next.isCompleted) next.complete();
      }
    });
  }
}
/// Thread-of-execution safe in-memory store. Not intended for horizontal
/// multi-instance scaling; documented in README as a mock/embedded store that
/// is trivially replaced by a transactional DB (SQL transaction or a
/// Firestore/Firebase runTransaction).
class AppointmentStore {
  final Map<String, Slot> _slots = {};
  final List<Booking> _bookings = [];
  final AsyncLock _lock = AsyncLock();
  final StreamController<BookingEvent> _events =
      StreamController<BookingEvent>.broadcast();

  int _slotCounter = 0;
  int _bookingCounter = 0;

  /// Broadcast of newly confirmed bookings (realtime admin updates).
  Stream<BookingEvent> get onBookingCreated => _events.stream;

  // ---- Slot administration -------------------------------------------------

  /// Create a new admin-defined [Slot]. Returns its id.
  Future<String> addSlot({
    required DateTime startTime,
    required DateTime endTime,
    required int capacity,
    String? adminNote,
  }) {
    return _lock.synchronize(() async {
      _slotCounter++;
      final slot = Slot(
        id: 's$_slotCounter',
        startTime: startTime,
        endTime: endTime,
        capacity: capacity,
        adminNote: adminNote,
      );
      _slots[slot.id] = slot;
      return slot.id;
    });
  }

  Future<void> updateSlotCapacity(String slotId, int capacity) {
    return _lock.synchronize(() async {
      if (!_slots.containsKey(slotId)) {
        throw StateError('Slot $slotId does not exist');
      }
      final old = _slots[slotId]!;
      if (capacity < 1) {
        throw ArgumentError.value(capacity, 'capacity', 'must be >= 1');
      }
      _slots[slotId] = Slot(
        id: old.id,
        startTime: old.startTime,
        endTime: old.endTime,
        capacity: capacity,
        adminNote: old.adminNote,
      );
    });
  }

  Future<void> removeSlot(String slotId) {
    return _lock.synchronize(() async {
      // Non-destructive semantics: only remove a slot that has no bookings.
      final hasBookings = _bookings.any((b) => b.slotId == slotId);
      if (hasBookings) {
        throw StateError('Cannot remove slot $slotId: users already booked it');
      }
      _slots.remove(slotId);
    });
  }

  /// Seed a handful of demo slots for a specific date. Used by tests.
  /// Inserts directly under the existing outer lock( do not call [addSlot]
  /// here, which would re-acquire the lock and deadlock).
  Future<List<Slot>> seedDemoSlots(String date, {int capacity = 5}) {
    return _lock.synchronize(() async {
      final day = DateTime.parse(date);
      final seeded = <Slot>[];
      for (final h in [9, 10, 14, 15]) {
        _slotCounter++;
        final slot = Slot(
          id: 's$_slotCounter',
          startTime: DateTime(day.year, day.month, day.day, h, 0),
          endTime: DateTime(day.year, day.month, day.day, h, 45),
          capacity: capacity,
          adminNote: 'Tư vấn tâm lý 45 phút',
        );
        _slots[slot.id] = slot;
        seeded.add(slot);
      }
      return seeded;
    });
  }

  // ---- Reads ---------------------------------------------------------------

  Slot? slotById(String slotId) => _slots[slotId];

  List<Slot> slotsForDate(DateTime date) {
    return _slots.values
        .where((s) =>
            s.startTime.year == date.year &&
            s.startTime.month == date.month &&
            s.startTime.day == date.day)
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  List<Slot> allSlots() => _slots.values.toList();

  List<Booking> bookingsForSlot(String slotId) {
    return _bookings.where((b) => b.slotId == slotId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  List<Booking> bookingsForUser(String userId) {
    return _bookings.where((b) => b.userId == userId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  // ---- Booking transaction -------------------------------------------------

  /// Creates a booking atomically. Returns a [BookingResult]; on success the
  /// booking is appended and a [BookingEvent] is broadcast for the SSE bus.
  Future<BookingResult> createBooking({
    required String slotId,
    required String userId,
    required String userName,
    required String userEmail,
  }) {
    return _lock.synchronize(() async {
      final slot = _slots[slotId];
      if (slot == null) return BookingSlotNotFound(slotId);

      final trimmedName = userName.trim();
      final trimmedEmail = userEmail.trim();
      if (userId.trim().isEmpty || trimmedName.isEmpty || trimmedEmail.isEmpty) {
        return const BookingInvalid(
          'Yêu cầu thiếu thông tin: vui lòng cung cấp userId, userName và userEmail hợp lệ.',
        );
      }

      // Duplicate: the same user cannot book the same slot twice.
      final alreadyBooked =
          _bookings.any((b) => b.slotId == slotId && b.userId == userId);
      if (alreadyBooked) return const BookingDuplicate();

      // Capacity: reject before inserting when the slot is full.
      final taken = slot.registrationCount(_bookings);
      if (taken >= slot.capacity) return BookingSlotFull(slot);

      _bookingCounter++;
      final booking = Booking(
        bookingId: 'b$_bookingCounter',
        slotId: slotId,
        userId: userId,
        userName: trimmedName,
        userEmail: trimmedEmail,
        createdAt: DateTime.now().toUtc(),
      );
      _bookings.add(booking);
      _events.add(BookingEvent(booking));
      return BookingCreated(booking);
    });
  }

  /// Total bookings in the store (used by tests/admin overview).
  int get totalBookings => _bookings.length;

  /// Reset store state (mostly for tests).
  Future<void> reset() {
    return _lock.synchronize(() async {
      _slots.clear();
      _bookings.clear();
      _slotCounter = 0;
      _bookingCounter = 0;
    });
  }

  void dispose() {
    _events.close();
  }
}