;;;; Snapshot and other data to restore frame locals

;;;; Copyright (C) 2014, 2015 Free Software Foundation, Inc.
;;;;
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;;;; 02110-1301 USA
;;;;

;;; Commentary:
;;;
;;; This module contains snapshot related codes and record type used when
;;; recovering frame locals. Snapshot data are used when restoring locals in
;;; frame, so that the VM interpreter can continue from where the native code
;;; has returned.
;;;
;;; Code:

(define-module (system vm native tjit snapshot)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (language cps types)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:use-module (system vm debug)
  #:use-module (system vm native debug)
  #:use-module (system vm native tjit parameters)
  #:export ($snapshot
            make-snapshot
            %make-snapshot
            snapshot?
            snapshot-id
            snapshot-sp-offset
            snapshot-fp-offset
            snapshot-nlocals
            snapshot-locals
            snapshot-variables
            set-snapshot-variables!
            set-snapshot-code!
            snapshot-ip

            snapshot-jump-to-linked-code?
            snapshot-set-loop-info?
            *ip-key-jump-to-linked-code*
            *ip-key-set-loop-info!*

            $past-frame
            make-past-frame
            past-frame-local-indices
            past-frame-local-ref
            past-frame-sp-offsets
            past-frame-fp-offsets
            past-frame-dls
            past-frame-ras
            pop-past-frame!
            push-past-frame!

            $return-address
            make-return-address
            return-address?
            return-address-ip

            $dynamic-link
            make-dynamic-link
            dynamic-link?
            dynamic-link-offset

            fixnum?
            flonum?
            unbound?
            true?
            false?
            type-of
            addr->source-line
            pretty-type)
  #:re-export (&exact-integer
               &flonum
               &char
               &unspecified
               &unbound
               &false
               &true
               &nil
               &null
               &symbol
               &keyword
               &procedure
               &pointer
               &fluid
               &vector
               &box
               &struct
               &bytevector
               &bitvector
               &array
               &hash-table))


;;;
;;; Record types
;;;

;; Record type to represent return address in frame.
(define-record-type $return-address
  (make-return-address ip)
  return-address?
  (ip return-address-ip))

;; Record type to represent dynamic link in frame.
(define-record-type $dynamic-link
  (make-dynamic-link offset)
  dynamic-link?
  (offset dynamic-link-offset))

;; Data type to contain past frame data.
;;
;; Stores dynamic link, return addresses, and locals of caller procedure when
;; inlined procedure exist in trace.
(define-record-type $past-frame
  (%make-past-frame dls ras locals local-indices sp-offsets fp-offsets)
  past-frame?

  ;; Association list for dynamic link: (local . pointer to fp).
  (dls past-frame-dls set-past-frame-dls!)

  ;; Association list for return address: (local . pointer to ra).
  (ras past-frame-ras set-past-frame-ras!)

  ;; Vector containing locals.
  (locals past-frame-locals set-past-frame-locals!)

  ;; All local indices found in trace.
  (local-indices past-frame-local-indices)

  ;; Vector containing SP offset per bytecode operation.
  (sp-offsets past-frame-sp-offsets)

  ;; Vector containing FP offset per bytecode operation.
  (fp-offsets past-frame-fp-offsets))

(define (make-past-frame dls ras local-offset locals local-indices
                         sp-offsets fp-offsets)
  ;; Using hash-table to contain locals, since local index could take negative
  ;; value.
  (let ((table (make-hash-table))
        (nlocals (vector-length locals)))
    (let lp ((i 0) (end nlocals))
      (when (< i end)
        (let ((elem (and (vector-ref locals i)))
              (j (+ i local-offset)))
          (hashq-set! table j elem))
        (lp (+ i 1) end)))
    (%make-past-frame dls ras table local-indices sp-offsets fp-offsets)))

(define (push-past-frame! past-frame dl ra local-offset locals)
  (set-past-frame-dls! past-frame (cons dl (past-frame-dls past-frame)))
  (set-past-frame-ras! past-frame (cons ra (past-frame-ras past-frame)))
  (let lp ((i 0)
           (end (vector-length locals))
           (to-update (past-frame-locals past-frame)))
    (when (< i end)
      (hashq-set! to-update (+ i local-offset) (vector-ref locals i))
      (lp (+ i 1) end to-update)))
  past-frame)

(define (pop-past-frame! past-frame)
  (let ((old-dls (past-frame-dls past-frame))
        (old-ras (past-frame-ras past-frame)))
    (when (not (null? old-dls))
      (set-past-frame-dls! past-frame (cdr old-dls)))
    (when (not (null? old-ras))
      (set-past-frame-ras! past-frame (cdr old-ras)))
    past-frame))

(define (past-frame-local-ref past-frame i)
  (hashq-get-handle (past-frame-locals past-frame) i))

;; Record type for snapshot.
(define-record-type $snapshot
  (%make-snapshot id sp-offset fp-offset nlocals locals variables code ip)
  snapshot?

  ;; ID number of this snapshot.
  (id snapshot-id)

  ;; Integer number to shift SP after returning with this snapshot.
  (sp-offset snapshot-sp-offset)

  ;; Integer number to shift vp->fp after returning with this snapshot.
  (fp-offset snapshot-fp-offset)

  ;; Number of locals at the time of snapshot.
  (nlocals snapshot-nlocals)

  ;; Association list of (local . type).
  (locals snapshot-locals)

  ;; Variables used at the time of taking exit.
  (variables snapshot-variables set-snapshot-variables!)

  ;; Native code of bailout with this snapshot.
  (code snapshot-code set-snapshot-code!)

  ;; Bytecode IP of this snapshot to return.
  (ip snapshot-ip))


;;;
;;; Type checker based on runtime values
;;;

(define (fixnum? val)
  (and (exact-integer? val)
       (<= most-negative-fixnum val most-positive-fixnum)))

(define (flonum? val)
  (and (real? val) (inexact? val)))

(define (unbound? x)
  (= (pointer-address (scm->pointer x)) #x904))

(define (false? x)
  (not x))

(define (true? x)
  (eq? x #t))

(define (type-of obj)
  (cond
   ((fixnum? obj) &exact-integer)
   ((flonum? obj) &flonum)
   ((char? obj) &char)
   ((unspecified? obj) &unspecified)
   ((unbound? obj) &unbound)
   ((false? obj) &false)
   ((true? obj) &true)
   ((procedure? obj) &procedure)
   ((pair? obj) &pair)
   ((null? obj) &null)
   ((variable? obj) &box)
   ((struct? obj) &struct)
   ((bytevector? obj) &bytevector)
   ((bitvector? obj) &bitvector)
   (else
    (debug 3 "*** Type not determined: ~a~%" obj)
    #f)))

(define-syntax-rule (addr->source-line addr)
  (cond
   ((find-source-for-addr addr)
    => (lambda (source)
         (format #f "~a:~d"
                 (let ((file (source-file source)))
                   (or (and (string? file) (basename file))
                       "(unknown file)"))
                 (source-line-for-user source))))
   (else
    "(invalid IP)")))

(define (pretty-type type)
  "Show string representation of TYPE."
  (cond
   ((eq? type &exact-integer) (blue "snum"))
   ((eq? type &flonum) (magenta "fnum"))
   ((eq? type &char) (blue "char"))
   ((eq? type &unspecified) (green "uspc"))
   ((eq? type &unbound) (green "ubnd"))
   ((eq? type &false) (green "fals"))
   ((eq? type &true) (green "true"))
   ((eq? type &nil) (green "nil"))
   ((eq? type &null) (green "null"))
   ((eq? type &symbol) (blue "symb"))
   ((eq? type &keyword) (blue "keyw"))
   ((eq? type &procedure) (red "proc"))
   ((eq? type &pair) (yellow "pair"))
   ((eq? type &vector) (yellow "vect"))
   ((eq? type &box) (yellow "box"))
   ((eq? type &struct) (yellow "strc"))
   ((dynamic-link? type)
    (let ((diff (number->string (dynamic-link-offset type))))
      (string-append "dl:" (cyan diff))))
   ((return-address? type)
    (let* ((addr (pointer-address (return-address-ip type)))
           (hex-ip (number->string addr 16)))
      (string-append "ra:" (cyan hex-ip))))
   (else type)))


;;;
;;; Snapshot
;;;

(define (make-snapshot id sp-offset fp-offset lowest-offset nlocals
                       locals parent-snapshot indices past-frame ip)
  (define-syntax-rule (local-ref i)
    (vector-ref locals i))
  (define initial-offset
    (or (and=> parent-snapshot snapshot-sp-offset)))
  (define parent-locals
    (and=> parent-snapshot snapshot-locals))
  (define (parent-snapshot-local-ref i)
    (and parent-snapshot
         (assq-ref parent-locals i)
         ;; (assq-ref parent-locals (if (< 0 initial-offset)
         ;;                             i
         ;;                             (- i initial-offset)))
         ))
  (define (shift-lowest acc)
    (map (match-lambda
          ((n . local)
           `(,(- n lowest-offset) . ,local)))
         acc))
  (let lp ((is indices) (acc '()))
    (match is
      ((i . is)
       (define (dl-or-ra i)
         (or (assq-ref (past-frame-dls past-frame) i)
             (assq-ref (past-frame-ras past-frame) i)
             (let ((val (parent-snapshot-local-ref i)))
               (and (or (dynamic-link? val)
                        (return-address? val))
                    val))))
       (define (add-local local)
         (let ((type (type-of local)))
           (lp is (cons `(,i . ,type) acc))))
       (define (add-val val)
         (lp is (cons `(,i . ,val) acc)))
       (cond
        ;; Inlined local in initial frame in root trace. The frame contents
        ;; should be a scheme value, not dynamic link or return address.
        ((< (- sp-offset 1) i (+ sp-offset nlocals))
         (add-local (local-ref (- i sp-offset))))

        ;; Dynamic link and return address might need to be passed from parent
        ;; trace. When side trace of inlined procedure takes bailout code,
        ;; recorded trace might not contain bytecode operation to fill in the
        ;; dynamic link and return address of past frame.
        ((dl-or-ra i)
         => add-val)

        ;; Local from a vector saved at the tme of recording the trace.
        ((< -1 (- i sp-offset) (vector-length locals))
         (add-local (local-ref (- i sp-offset))))

        ;; When side trace contains inlined procedure and the guard taking this
        ;; snapshot is from the caller of the inlined procedure, saving local in
        ;; upper frame. Looking up locals from newest locals in past-frame.
        ((past-frame-local-ref past-frame i)
         => (match-lambda ((_ . local)
                           (add-local local))))

        ;; Side trace could start from the middle of inlined procedure, locals
        ;; in past frame may not have enough information to recover locals in
        ;; caller of the inlined procedure. In such case, look up locals in the
        ;; snapshot of parent trace.
        ((parent-snapshot-local-ref i)
         => add-val)

        ;; Giving up, skip this local.
        (else
         (debug 3 "XXX: local for i=~a not found~%" i)
         (add-local #f))))
      (()
       (let ((acc (reverse! acc)))
         (%make-snapshot id
                         sp-offset
                         fp-offset
                         (vector-length locals)
                         ;; (shift-lowest acc)
                         acc
                         #f
                         #f
                         ip))))))

;;;
;;; IP Keys
;;;

(define *ip-key-jump-to-linked-code* 0)
(define *ip-key-set-loop-info!* 1)

(define (snapshot-jump-to-linked-code? snapshot)
  (= (snapshot-ip snapshot) *ip-key-jump-to-linked-code*))

(define (snapshot-set-loop-info? snapshot)
  (= (snapshot-ip snapshot) *ip-key-set-loop-info!*))