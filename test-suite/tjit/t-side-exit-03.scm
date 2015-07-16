(define (loop n)
  (let lp ((i 0) (acc1 0) (acc2 0))
    (cond
     ((= i n)
      (list acc1 acc2))
     ((< 800 i)
      (lp (+ i 1) acc1 acc2))
     (else
      (set! acc1 (+ acc1 1))
      (cond
       ((< i 100)
        (lp (+ i 1) acc1 acc2))
       (else
        (lp (+ i 1) acc1 (+ acc2 1))))))))

(loop #e1e3)