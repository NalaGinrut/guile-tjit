(let ((set-counter2 #f))
  (define (get-counter2)
    (call/cc
     (lambda (k)
       (set! set-counter2 k)
       1)))
  (define (loop counter1)
    (let ((counter2 (get-counter2)))
      (set! counter1 (1+ counter1))
      (cond ((not (= counter1 counter2))
             (error "bad call/cc behaviour" counter1 counter2))
            ((> counter1 10)
             #t)
            (else
             (set-counter2 (1+ counter2))))))
  (loop 0))
