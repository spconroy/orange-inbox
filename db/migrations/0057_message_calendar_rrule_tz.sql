-- Thread detail reads these fields from message_calendar_events in the
-- primary mail database too. Overflow databases already receive them through
-- mail-plane-bootstrap.sql or scripts/0003_mail_db_rrule_tz.sql.
ALTER TABLE message_calendar_events ADD COLUMN rrule TEXT;
ALTER TABLE message_calendar_events ADD COLUMN tz TEXT;
