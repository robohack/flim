;;; smtp.el --- basic functions to send mail with SMTP server

;; Copyright (C) 1995, 1996, 1998, 1999, 2000 Free Software Foundation, Inc.

;; Author: Tomoji Kagatani <kagatani@rbc.ncl.omron.co.jp>
;;	Simon Leinen <simon@switch.ch> (ESMTP support)
;;	Shuhei KOBAYASHI <shuhei@aqua.ocn.ne.jp>
;;	Daiki Ueno <ueno@unixuser.org>
;; Keywords: SMTP, mail

;; This file is part of FLIM (Faithful Library about Internet Message).

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.


;;; Commentary:
;;

;;; Code:

(require 'pces)
(require 'pcustom)
(require 'mail-utils)			; mail-strip-quoted-names
(require 'sasl)
(require 'luna)
(require 'mel) ; binary-funcall

(defgroup smtp nil
  "SMTP protocol for sending mail."
  :group 'mail)

(defgroup smtp-extensions nil
  "SMTP service extensions (RFC1869)."
  :group 'smtp)

(defcustom smtp-default-server nil
  "Specify default SMTP server."
  :type '(choice (const nil) string)
  :group 'smtp)

(defcustom smtp-server (or (getenv "SMTPSERVER") smtp-default-server)
  "The name of the host running SMTP server.
It can also be a function
called from `smtp-via-smtp' with arguments SENDER and RECIPIENTS."
  :type '(choice (string :tag "Name")
		 (function :tag "Function"))
  :group 'smtp)

(defcustom smtp-service "smtp"
  "SMTP service port number.  \"smtp\" or 25."
  :type '(choice (integer :tag "25" 25)
		 (string :tag "smtp" "smtp"))
  :group 'smtp)

(defcustom smtp-local-domain nil
  "Local domain name without a host name.
If the function (system-name) returns the full internet address,
don't define this value."
  :type '(choice (const nil) string)
  :group 'smtp)

(defcustom smtp-fqdn nil
  "Fully qualified domain name used for Message-ID."
  :type '(choice (const nil) string)
  :group 'smtp)

(defcustom smtp-use-8bitmime t
  "If non-nil, use ESMTP 8BITMIME (RFC1652) if available."
  :type 'boolean
  :group 'smtp-extensions)

(defcustom smtp-use-size t
  "If non-nil, use ESMTP SIZE (RFC1870) if available."
  :type 'boolean
  :group 'smtp-extensions)

(defcustom smtp-use-starttls nil
  "If non-nil, use STARTTLS (RFC2595) if available."
  :type 'boolean
  :group 'smtp-extensions)

(defcustom smtp-use-sasl nil
  "If non-nil, use SMTP Authentication (RFC2554) if available."
  :type 'boolean
  :group 'smtp-extensions)

(defcustom smtp-sasl-user-name (user-login-name)
  "Identification to be used for authorization."
  :type 'string
  :group 'smtp-extensions)

(defcustom smtp-sasl-properties nil
  "Properties set to SASL client."
  :type 'string
  :group 'smtp-extensions)

(defcustom smtp-sasl-mechanisms nil
  "List of authentication mechanisms."
  :type '(repeat string)
  :group 'smtp-extensions)

(defvar sasl-mechanisms)
;;;###autoload
(defvar smtp-open-connection-function (function open-network-stream))

(defvar smtp-read-point nil)

(defvar smtp-connection-alist nil)

(defvar smtp-submit-package-function (function smtp-submit-package))

;;; @ SMTP package
;;; A package contains a mail message, an envelope sender address,
;;; and one or more envelope recipient addresses.  In ESMTP model
;;; the current sending package should be guaranteed to be accessible
;;; anywhere from the hook methods (or SMTP commands).

(eval-and-compile
  (luna-define-class smtp-package ()
		     (sender
		      recipients
		      buffer))

  (luna-define-internal-accessors 'smtp-package))

(defun smtp-make-package (sender recipients buffer)
  "Create a new package structure.
A package is a unit of SMTP message
SENDER specifies the package sender, a string.
RECIPIENTS is a list of recipients.
BUFFER may be a buffer or a buffer name which contains mail message."
  (luna-make-entity 'smtp-package :sender sender :recipients recipients :buffer buffer))

(defun smtp-package-buffer-internal-size (package)
  "Return the size of PACKAGE, an integer."
  (save-excursion
    (set-buffer (smtp-package-buffer-internal package))
    (let ((size
	   (+ (buffer-size)
	      ;; Add one byte for each change-of-line
	      ;; because or CR-LF representation:
	      (count-lines (point-min) (point-max))
	      ;; For some reason, an empty line is
	      ;; added to the message.	Maybe this
	      ;; is a bug, but it can't hurt to add
	      ;; those two bytes anyway:
	      2)))
      (goto-char (point-min))
      (while (re-search-forward "^\\." nil t)
	(setq size (1+ size)))
      size)))

;;; @ SMTP connection
;;; We should consider the function `open-network-stream' is a emulation
;;; for another network stream.  They are likely to be implemented with an
;;; external program and the function `process-contact' returns the
;;; process id instead of `(HOST SERVICE)' pair.

(eval-and-compile
  (luna-define-class smtp-connection ()
		     (process
		      server
		      service
		      extensions
		      encoder
		      decoder))

  (luna-define-internal-accessors 'smtp-connection))

(defun smtp-make-connection (process server service)
  "Create a new connection structure.
PROCESS is an internal subprocess-object.  SERVER is name of the host
to connect to.  SERVICE is name of the service desired."
  (luna-make-entity 'smtp-connection :process process :server server :service service))

(luna-define-generic smtp-connection-opened (connection)
  "Say whether the CONNECTION to server has been opened.")

(luna-define-generic smtp-close-connection (connection)
  "Close the CONNECTION to server.")

(luna-define-method smtp-connection-opened ((connection smtp-connection))
  (let ((process (smtp-connection-process-internal connection)))
    (if (memq (process-status process) '(open run))
	t)))

(luna-define-method smtp-close-connection ((connection smtp-connection))
  (let ((process (smtp-connection-process-internal connection)))
    (delete-process process)))

(defun smtp-make-fqdn ()
  "Return user's fully qualified domain name."
  (if smtp-fqdn
      smtp-fqdn
    (let ((system-name (system-name)))
      (cond
       (smtp-local-domain
	(concat system-name "." smtp-local-domain))
       ((string-match "[^.]\\.[^.]" system-name)
	system-name)
       (t
	(error "Cannot generate valid FQDN"))))))

(defun smtp-find-connection (buffer)
  "Find the connection delivering to BUFFER."
  (let ((entry (assq buffer smtp-connection-alist))
	connection)
    (when entry
      (setq connection (nth 1 entry))
      (if (smtp-connection-opened connection)
	  connection
	(setq smtp-connection-alist
	      (delq entry smtp-connection-alist))
	nil))))

(eval-and-compile
  (autoload 'starttls-open-stream "starttls")
  (autoload 'starttls-negotiate "starttls"))

(defun smtp-open-connection (buffer server service)
  "Open a SMTP connection for a service to a host.
Return a newly allocated connection-object.
BUFFER is the buffer to associate with the connection.  SERVER is name
of the host to connect to.  SERVICE is name of the service desired."
  (let* ((process
	  (binary-funcall smtp-open-connection-function
			  "SMTP" buffer  server service))
	 connection)
    (when process
      (setq connection (smtp-make-connection process server service))
      (set-process-filter process 'smtp-process-filter)
      (setq smtp-connection-alist
	    (cons (list buffer connection)
		  smtp-connection-alist))
      connection)))

;;;###autoload
(defun smtp-via-smtp (sender recipients buffer)
  "Like `smtp-send-buffer', but sucks in any errors."
  (condition-case nil
      (progn
	(smtp-send-buffer sender recipients buffer)
	t)
    (smtp-error)))

(make-obsolete 'smtp-via-smtp "It's old API.")

;;;###autoload
(defun smtp-send-buffer (sender recipients buffer)
  "Send a message.
SENDER is an envelope sender address.
RECIPIENTS is a list of envelope recipient addresses.
BUFFER may be a buffer or a buffer name which contains mail message."
  (let ((server
	 (if (functionp smtp-server)
	     (funcall smtp-server sender recipients)
	   smtp-server))
	(package
	 (smtp-make-package sender recipients buffer))
	(smtp-open-connection-function
	 (if smtp-use-starttls
	     (function starttls-open-stream)
	   smtp-open-connection-function)))
    (save-excursion
      (set-buffer
       (get-buffer-create
	(format "*trace of SMTP session to %s*" server)))
      (erase-buffer)
      (buffer-disable-undo (current-buffer))
      (unless (smtp-find-connection (current-buffer))
	(smtp-open-connection (current-buffer) server smtp-service))
      (make-local-variable 'smtp-read-point)
      (setq smtp-read-point (point-min))
      (funcall smtp-submit-package-function package))))

(defun smtp-submit-package (package)
  (unwind-protect
      (progn
	(smtp-primitive-greeting package)
	(condition-case nil
	    (smtp-primitive-ehlo package)
	  (smtp-response-error
	   (smtp-primitive-helo package)))
	(if smtp-use-starttls
	    (smtp-primitive-starttls package))
	(if smtp-use-sasl
	    (smtp-primitive-auth package))
	(smtp-primitive-mailfrom package)
	(smtp-primitive-rcptto package)
	(smtp-primitive-data package))
    (let ((connection (smtp-find-connection (current-buffer))))
      (when (smtp-connection-opened connection)
	(smtp-primitive-quit package)
	(smtp-close-connection connection)))))

;;; @ hook methods for `smtp-submit-package'
;;;

(defun smtp-primitive-greeting (package)
  (let* ((connection
	  (smtp-find-connection (current-buffer)))
	 (response
	  (smtp-read-response connection)))
    (if (/= (car response) 220)
	(smtp-response-error response))))

(defun smtp-primitive-ehlo (package)
  (let* ((connection
	  (smtp-find-connection (current-buffer)))
	 response)
    (smtp-send-command connection (format "EHLO %s" (smtp-make-fqdn)))
    (setq response (smtp-read-response connection))
    (if (/= (car response) 250)
	(smtp-response-error response))
    (smtp-connection-set-extensions-internal
     connection (mapcar
		 (lambda (extension)
		   (let ((extensions
			  (split-string extension)))
		     (setcar extensions
			     (car (read-from-string
				   (downcase (car extensions)))))
		     extensions))
		 (cdr response)))))

(defun smtp-primitive-helo (package)
  (let* ((connection
	  (smtp-find-connection (current-buffer)))
	 response)
    (smtp-send-command connection (format "HELO %s" (smtp-make-fqdn)))
    (setq response (smtp-read-response connection))
    (if (/= (car response) 250)
	(smtp-response-error response))))

(defun smtp-primitive-auth (package)
  (let* ((connection
	  (smtp-find-connection (current-buffer)))
	 (mechanisms
	  (cdr (assq 'auth (smtp-connection-extensions-internal connection))))
	 (sasl-mechanisms
	  (or smtp-sasl-mechanisms sasl-mechanisms))
	 (mechanism
	  (sasl-find-mechanism mechanisms))
	 client
	 name
	 step
	 response)
    (unless mechanism
      (error "No authentication mechanism available"))
    (setq client (sasl-make-client mechanism smtp-sasl-user-name "smtp"
				   (smtp-connection-server-internal connection)))
    (if smtp-sasl-properties
	(sasl-client-set-properties client smtp-sasl-properties))
    (setq name (sasl-mechanism-name mechanism)
	  ;; Retrieve the initial response
	  step (sasl-next-step client nil))
    (smtp-send-command
     connection
     (if (sasl-step-data step)
	 (format "AUTH %s %s" name (base64-encode-string (sasl-step-data step) t))
       (format "AUTH %s" name)))
    (catch 'done
      (while t
	(setq response (smtp-read-response connection))
	(when (= (car response) 235)
	  ;; The authentication process is finished.
	  (setq step (sasl-next-step client step))
	  (if (null step)
	      (throw 'done nil))
	  (smtp-response-error response)) ;Bogus server?
	(if (/= (car response) 334)
	    (smtp-response-error response))
	(sasl-step-set-data step (base64-decode-string (nth 1 response)))
	(setq step (sasl-next-step client step))
	(smtp-send-command
	 connection
	 (if (sasl-step-data step)
	     (base64-encode-string (sasl-step-data step) t)
	   ""))))
    ;;;    (smtp-connection-set-encoder-internal
    ;;;     connection (sasl-client-encoder client))
    ;;;    (smtp-connection-set-decoder-internal
    ;;;     connection (sasl-client-decoder client))
    ))

(defun smtp-primitive-starttls (package)
  (let* ((connection
	  (smtp-find-connection (current-buffer)))
	 response)
    ;; STARTTLS --- begin a TLS negotiation (RFC 2595)
    (smtp-send-command connection "STARTTLS")
    (setq response (smtp-read-response connection))
    (if (/= (car response) 220)
	(smtp-response-error response))
    (starttls-negotiate (smtp-connection-process-internal connection))))

(defun smtp-primitive-mailfrom (package)
  (let* ((connection
	  (smtp-find-connection (current-buffer)))
	 (extensions
	  (smtp-connection-extensions-internal
	   connection))
	 (sender
	  (smtp-package-sender-internal package))
	 extension
	 response)
    ;; SIZE --- Message Size Declaration (RFC1870)
    (if (and smtp-use-size
	     (assq 'size extensions))
	(setq extension (format "SIZE=%d" (smtp-package-buffer-internal-size package))))
    ;; 8BITMIME --- 8bit-MIMEtransport (RFC1652)
    (if (and smtp-use-8bitmime
	     (assq '8bitmime extensions))
	(setq extension (concat extension " BODY=8BITMIME")))
    (smtp-send-command
     connection
     (if extension
	 (format "MAIL FROM:<%s> %s" sender extension)
       (format "MAIL FROM:<%s>" sender)))
    (setq response (smtp-read-response connection))
    (if (/= (car response) 250)
	(smtp-response-error response))))

(defun smtp-primitive-rcptto (package)
  (let* ((connection
	  (smtp-find-connection (current-buffer)))
	 (recipients
	  (smtp-package-recipients-internal package))
	 response)
    (while recipients
      (smtp-send-command
       connection (format "RCPT TO:<%s>" (pop recipients)))
      (setq response (smtp-read-response connection))
      (unless (memq (car response) '(250 251))
	(smtp-response-error response)))))

(defun smtp-primitive-data (package)
  (let* ((connection
	  (smtp-find-connection (current-buffer)))
	 response)
    (smtp-send-command connection "DATA")
    (setq response (smtp-read-response connection))
    (if (/= (car response) 354)
	(smtp-response-error response))
    (save-excursion
      (set-buffer (smtp-package-buffer-internal package))
      (goto-char (point-min))
      (while (not (eobp))
	(smtp-send-data
	 connection (buffer-substring (point) (progn (end-of-line)(point))))
	(beginning-of-line 2)))
    (smtp-send-command connection ".")
    (setq response (smtp-read-response connection))
    (if (/= (car response) 250)
	(smtp-response-error response))))

(defun smtp-primitive-quit (package)
  (let* ((connection
	  (smtp-find-connection (current-buffer)))
	 response)
    (smtp-send-command connection "QUIT")
    (setq response (smtp-read-response connection))
    (if (/= (car response) 221)
	(smtp-response-error response))))

;;; @ low level process manipulating function
;;;
(defun smtp-process-filter (process output)
  (save-excursion
    (set-buffer (process-buffer process))
    (goto-char (point-max))
    (insert output)))

(put 'smtp-error 'error-message "SMTP error")
(put 'smtp-error 'error-conditions '(smtp-error error))

(put 'smtp-response-error 'error-message "SMTP response error")
(put 'smtp-response-error 'error-conditions '(smtp-response-error smtp-error error))

(defun smtp-response-error (response)
  (signal 'smtp-response-error response))

(defun smtp-read-response (connection)
  (let ((decoder
	 (smtp-connection-decoder-internal connection))
	(response-continue t)
	response)
    (while response-continue
      (goto-char smtp-read-point)
      (while (not (search-forward "\r\n" nil t))
	(accept-process-output (smtp-connection-process-internal connection))
	(goto-char smtp-read-point))
      (if decoder
	  (let ((string (buffer-substring smtp-read-point (- (point) 2))))
	    (delete-region smtp-read-point (point))
	    (insert (funcall decoder string) "\r\n")))
      (setq response
	    (nconc response
		   (list (buffer-substring
			  (+ 4 smtp-read-point)
			  (- (point) 2)))))
      (goto-char
       (prog1 smtp-read-point
	 (setq smtp-read-point (point))))
      (if (looking-at "[1-5][0-9][0-9] ")
	  (setq response (cons (read (point-marker)) response)
		response-continue nil)))
    response))

(defun smtp-send-command (connection command)
  (save-excursion
    (let ((process
	   (smtp-connection-process-internal connection))
	  (encoder
	   (smtp-connection-encoder-internal connection)))
      (set-buffer (process-buffer process))
      (goto-char (point-max))
      (setq command (concat command "\r\n"))
      (insert command)
      (setq smtp-read-point (point))
      (if encoder
	  (setq command (funcall encoder command)))
      (process-send-string process command))))

(defun smtp-send-data (connection data)
  (let ((process
	 (smtp-connection-process-internal connection))
	(encoder
	 (smtp-connection-encoder-internal connection)))
    ;; Escape "." at start of a line.
    (if (eq (string-to-char data) ?.)
	(setq data (concat "." data "\r\n"))
      (setq data (concat data "\r\n")))
    (if encoder
	(setq data (funcall encoder data)))
    (process-send-string process data)))

(defun smtp-deduce-address-list (smtp-text-buffer header-start header-end)
  "Get address list suitable for smtp RCPT TO:<address>."
  (let ((simple-address-list "")
	this-line
	this-line-end
	addr-regexp
	(smtp-address-buffer (generate-new-buffer " *smtp-mail*")))
    (unwind-protect
	(save-excursion
	  ;;
	  (set-buffer smtp-address-buffer)
	  (setq case-fold-search t)
	  (erase-buffer)
	  (insert (save-excursion
		    (set-buffer smtp-text-buffer)
		    (buffer-substring-no-properties header-start header-end)))
	  (goto-char (point-min))
	  ;; RESENT-* fields should stop processing of regular fields.
	  (save-excursion
	    (if (re-search-forward "^RESENT-TO:" header-end t)
		(setq addr-regexp
		      "^\\(RESENT-TO:\\|RESENT-CC:\\|RESENT-BCC:\\)")
	      (setq addr-regexp	 "^\\(TO:\\|CC:\\|BCC:\\)")))

	  (while (re-search-forward addr-regexp header-end t)
	    (replace-match "")
	    (setq this-line (match-beginning 0))
	    (forward-line 1)
	    ;; get any continuation lines.
	    (while (and (looking-at "^[ \t]+") (< (point) header-end))
	      (forward-line 1))
	    (setq this-line-end (point-marker))
	    (setq simple-address-list
		  (concat simple-address-list " "
			  (mail-strip-quoted-names
			   (buffer-substring this-line this-line-end)))))
	  (erase-buffer)
	  (insert-string " ")
	  (insert-string simple-address-list)
	  (insert-string "\n")
	  ;; newline --> blank
	  (subst-char-in-region (point-min) (point-max) 10 ?  t)
	  ;; comma   --> blank
	  (subst-char-in-region (point-min) (point-max) ?, ?  t)
	  ;; tab     --> blank
	  (subst-char-in-region (point-min) (point-max)	 9 ?  t)

	  (goto-char (point-min))
	  ;; tidyness in case hook is not robust when it looks at this
	  (while (re-search-forward "[ \t]+" header-end t) (replace-match " "))

	  (goto-char (point-min))
	  (let (recipient-address-list)
	    (while (re-search-forward " \\([^ ]+\\) " (point-max) t)
	      (backward-char 1)
	      (setq recipient-address-list
		    (cons (buffer-substring (match-beginning 1) (match-end 1))
			  recipient-address-list)))
	    recipient-address-list))
      (kill-buffer smtp-address-buffer))))

(provide 'smtp)

;;; smtp.el ends here
