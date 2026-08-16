;;;; src/notification.lisp
;;;;
;;;; LISTEN / NOTIFY.
;;;;
;;;; NOTIFY takes its channel as an identifier and its payload as a literal, so
;;;; neither can be a parameter; pg_notify is the function form of the same
;;;; command and takes both as text, which is why it is what NOTIFY sends. LISTEN
;;;; has no function form, so its channel is quoted as an identifier instead --
;;;; matching what pg_notify sends for the same string.

(in-package #:postgres-client)

(defun listen-channel (client channel)
  "Start delivering notifications sent to CHANNEL to CLIENT's connection.
Collect them with WAIT-FOR-NOTIFICATION."
  (execute client (concatenate 'string "LISTEN " (quote-identifier channel)))
  (values))

(defun unlisten-channel (client channel)
  "Stop delivering notifications sent to CHANNEL to CLIENT's connection.
A CHANNEL of \"*\" stops delivery on every channel."
  (execute client (if (equal channel "*")
                      "UNLISTEN *"
                      (concatenate 'string "UNLISTEN " (quote-identifier channel))))
  (values))

(defun notify (client channel &optional (payload ""))
  "Send a notification on CHANNEL with PAYLOAD.
Inside a transaction the notification is delivered when it commits, which is
what makes NOTIFY usable as an after-commit hook."
  (query-value client "select pg_notify(:channel, :payload)"
               :params (list :channel (string channel)
                             :payload (string payload)))
  (values))

(defun wait-for-notification (client)
  "Block until a notification arrives on a channel CLIENT listens to.
Returns three values: the channel, the payload, and the process id of the
backend that sent it.

This occupies the connection for as long as it blocks, so a program that also
runs queries needs a second client for listening."
  (cl-postgres:wait-for-notification (%client-connection client)))
