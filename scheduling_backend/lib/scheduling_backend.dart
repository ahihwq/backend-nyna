// lib/scheduling_backend.dart
/// Public library entrypoint for the consultation scheduling backend.
library;

export 'src/store.dart' show AppointmentStore, Slot, Booking, BookingResult,
    BookingCreated, BookingSlotFull, BookingSlotNotFound, BookingDuplicate,
    BookingInvalid, BookingEvent, AsyncLock;
export 'src/router.dart' show AppController, HandlerRequest, HandlerResponse,
    AuthKind, corsHeaders, corsPreflight;
export 'src/notifications.dart' show notifyNewBooking, retryWithBackoff,
    buildBookingNotifications, NotificationReport, FcmPayload, EmailPayload,
    defaultPushSender, defaultEmailSender;