.. _logging:

Logging
=======

By default, goiardi logs to standard output. A log file may be specified with the ``-L/--log-file`` flag, or goiardi can log to syslog with the ``-s/--syslog`` flag on platforms that support syslog. Attempting to use syslog on one of these platforms (currently Windows and plan9 (although plan9 doesn't build for other reasons)) will result in an error.

Log levels
----------

Log levels can be set in goiardi with either the ``log-level`` option in the configuration file, or with one to four -V flags on the command line. Log level options are "debug", "info", "warning", "error", and "critical". More ``-V`` on the command line means more spewing into the log.
