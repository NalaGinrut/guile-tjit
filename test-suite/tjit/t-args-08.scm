(define (micro a)
  (let lp ((a a) (b 0) (c 0) (d 0) (e 0) (f 0) (g 0) (h 0))
    (if (< 0 a)
        (lp (- a 1) (+ b 1) (+ c 1) (+ d 1) (+ e 1) (+ f 1) (+ g 1)
            (+ h 1))
        (+ a b c d e f g h))))

(micro #e1e3)
