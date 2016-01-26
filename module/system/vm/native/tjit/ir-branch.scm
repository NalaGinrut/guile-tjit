;;; ANF IR for branching

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
;;; Module containing ANF IR definitions for branching operations.
;;;
;;; Code:

(define-module (system vm native tjit ir-branch)
  #:use-module (system vm native tjit error)
  #:use-module (system vm native tjit ir)
  #:use-module (system vm native tjit snapshot)
  #:use-module (system vm native tjit variables))

(define-ir (br (const offset))
  ;; Nothing to emit for br.
  (next))

(define-ir (br-if-true (scm test) (const invert) (const offset))
  (let* ((test/v (var-ref test))
         (test/l (local-ref test))
         (dest (if test/l
                   (if invert offset 2)
                   (if invert 2 offset)))
         (op (if test/l '%ne '%eq)))
    `(let ((_ ,(take-snapshot! ip dest)))
       (let ((_ (,op ,test/v #f)))
         ,(next)))))

(define-ir (br-if-null (scm test) (const invert) (const offset))
  (let* ((test/l (local-ref test))
         (test/v (var-ref test))
         (dest (if (null? test/l)
                   (if invert offset 2)
                   (if invert 2 offset)))
         (op (if (null? test/l) '%eq '%ne)))
    `(let ((_ ,(take-snapshot! ip dest)))
       (let ((_ (,op ,test/v ())))
         ,(next)))))

;; XXX: br-if-nil

;; (define-ir (br-if-pair (scm test) (const invert) (const offset))
;;   (let* ((test/l (local-ref test))
;;          (test/v (var-ref test))
;;          (dest (if (pair? test/l)
;;                    (if invert offset 2)
;;                    (if invert 2 offset)))
;;          (tmp (make-tmpvar 2)))
;;     `(let ((_ ,(take-snapshot! ip dest)))
;;        ,(if (pair? test/l)
;;             `(let ((,tmp (%band ,test/v 6)))
;;                (let ((_ (%ne ,tmp 0)))
;;                  (let ((,tmp (%cref ,test/v 0)))
;;                    (let ((,tmp (%band ,tmp 1)))
;;                      (let ((_ (%eq ,tmp 0)))
;;                        ,(next))))))
;;             (nyi "br-if-pair ~s ~s ~s" test invert offset)))))

;; XXX: br-if-struct
;; XXX: br-if-char
;; XXX: br-if-tc7
;; XXX: br-if-eq
;; XXX: br-if-eqv
;; XXX: br-if-logtest

(define-syntax define-br-binary-body
  (syntax-rules ()
    ((_ name a b invert? offset test ra rb va vb dest . body)
     (let* ((ra (local-ref a))
            (rb (local-ref b))
            (va (var-ref a))
            (vb (var-ref b))
            (dest (if (and (number? ra)
                           (number? rb))
                      (if (test ra rb)
                          (if invert? offset 3)
                          (if invert? 3 offset))
                      (tjitc-error "~s: got ~s ~s" 'name ra rb))))
       . body))))

(define-syntax define-br-binary-scm-scm
  (syntax-rules ()
    ((_  name op-scm op-fx-t op-fx-f op-fl-t op-fl-f)
     (define-ir (name (scm a) (scm b) (const invert?) (const offset))
       (define-br-binary-body name a b invert? offset op-scm ra rb va vb dest
         (cond
          ((and (fixnum? ra) (fixnum? rb))
           `(let ((_ ,(take-snapshot! ip dest)))
              (let ((_ ,(if (op-scm ra rb)
                            `(op-fx-t ,va ,vb)
                            `(op-fx-f ,va ,vb))))
                ,(next))))
          ((and (flonum? ra) (flonum? rb))
           `(let ((_ ,(take-snapshot! ip dest)))
              (let ((_ ,(if (op-scm ra rb)
                            `(op-fl-t ,va ,vb)
                            `(op-fl-f ,va ,vb))))
                ,(next))))
          ;; XXX: Delegate bignum, complex ... etc to C function
          (else
           (nyi "~s: ~a ~a~%" 'name ra rb))))))))

(define-br-binary-scm-scm br-if-= = %eq %ne %feq %fne)
(define-br-binary-scm-scm br-if-< < %lt %ge %flt %fge)
(define-br-binary-scm-scm br-if-<= <= %le %gt %fle %fgt)

(define-syntax define-br-binary-u64-u64
  (syntax-rules ()
    ((_ name op-scm op-fx-t op-fx-f)
     (define-ir (name (u64 a) (u64 b) (const invert?) (const offset))
       (define-br-binary-body name a b invert? offset op-scm ra rb va vb dest
         `(let ((_ ,(take-snapshot! ip dest)))
            (let ((_ ,(if (op-scm ra rb)
                          `(op-fx-t ,va ,vb)
                          `(op-fx-f ,va ,vb))))
              ,(next))))))))

(define-br-binary-u64-u64 br-if-u64-= = %eq %ne)
(define-br-binary-u64-u64 br-if-u64-< < %lt %ge)
(define-br-binary-u64-u64 br-if-u64-<= <= %le %gt)

(define-syntax define-br-binary-u64-scm
  (syntax-rules ()
    ((_ name op-scm op-fx-t op-fx-f)
     (define-ir (name (u64 a) (scm b) (const invert?) (const offset))
       (define-br-binary-body name a b invert? offset op-scm ra rb va vb dest
         (let ((r2 (make-tmpvar 2)))
           `(let ((_ ,(take-snapshot! ip dest)))
              (let ((,r2 (%rsh ,vb 2)))
                (let ((_ ,(if (op-scm ra rb)
                              `(op-fx-t ,va ,r2)
                              `(op-fx-f ,va ,r2))))
                  ,(next))))))))))

(define-br-binary-u64-scm br-if-u64-=-scm = %eq %ne)
(define-br-binary-u64-scm br-if-u64-<-scm < %lt %ge)
(define-br-binary-u64-scm br-if-u64-<=-scm <= %le %gt)
(define-br-binary-u64-scm br-if-u64->-scm > %gt %le)
(define-br-binary-u64-scm br-if-u64->=-scm >= %ge %lt)