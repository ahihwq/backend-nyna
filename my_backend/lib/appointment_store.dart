// lib/appointment_store.dart
// Shared in-memory state for the consultation scheduling system.
//
// All three appointment routes (admin availability, public availability and
// bookings) import this single store so they observe the SAME live data:
//   - [weeklyTemplate]   : weekday (1 = Mon .. 7 = Sun) -> time slots
//                          (the slots the admin has predefined)
//   - [dateOverrides]    : specific date 'YYYY-MM-DD' -> time slots that
//                          override the weekly template for that date
//   - [availabilityConfirmed] : whether the admin has confirmed the schedule
//   - [bookings]         : every user registration for a date+time slot
library;

/// Admin weekly availability template.
final Map<int, List<String>> weeklyTemplate = {};

/// Per-date overrides of the weekly template.
final Map<String, List<String>> dateOverrides = {};

/// Whether the admin has confirmed this weekly schedule.
bool availabilityConfirmed = false;

/// Every booking registered by users.
/// Each booking: { id, studentName, date, time, createdAt, status }
final List<Map<String, dynamic>> bookings = [];