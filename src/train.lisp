(in-package :mgl-core)

(defsection @mgl-model (:title "Model")
  (@mgl-model-persistence section)
  (@mgl-model-stripe section))


(defsection @mgl-model-persistence (:title "Model Persistence")
  (read-weights generic-function)
  (write-weights generic-function)
  (load-weights function)
  (save-weights function))

(defgeneric read-weights (model stream)
  (:documentation "Read the weights of MODEL from the bivalent STREAM
  where weights mean the learnt parameters. There is currently no
  sanity checking of data which will most certainly change in the
  future together with the serialization format."))

(defgeneric write-weights (model stream)
  (:documentation "Write weight of MODEL to the bivalent STREAM."))

(defun load-weights (filename model)
  "Load weights of MODEL from FILENAME."
  (with-open-file (stream filename :element-type 'unsigned-byte)
    (read-weights model stream)))

(defun save-weights (filename model &key (if-exists :error)
                     (ensure t))
  "Save weights of MODEL to FILENAME. If ENSURE, then
  ENSURE-DIRECTORIES-EXIST is called on FILENAME. IF-EXISTS is passed
  on to OPEN."
  (when ensure
    (ensure-directories-exist filename))
  (with-open-file (stream filename :direction :output
                          :if-does-not-exist :create
                          :if-exists if-exists
                          :element-type 'unsigned-byte)
    (write-weights model stream)))


(defsection @mgl-model-stripe (:title "Batch Processing")
  "Processing instances one by one during training or prediction can
  be slow. The models that support batch processing for greater
  efficiency are said to be /striped/.

  Typically after creating a model, ones sets MAX-N-STRIPES on it a
  positive integer. When a batch of instances is to be fed to the
  model it is first broken into subbatches of length that's at most
  MAX-N-STRIPES. For each subbatch, SET-INPUT is called and a before
  method takes care of setting N-STRIPES to the actual number of
  instances in the subbatch. When MAX-N-STRIPES is set internal data
  structures may be resized which is an expensive operation. Setting
  N-STRIPES is a comparatively cheap operation, often implemented as
  matrix reshaping.

  Note that for models made of different parts (for example,
  [MGL-BP:BPN][CLASS] consists of [MGL-BP:LUMP][]s) , setting these
  values affects the constituent parts, but one should never change
  the number stripes of the parts directly because that would lead to
  an internal inconsistency in the model."
  (max-n-stripes generic-function)
  (set-max-n-stripes generic-function)
  (n-stripes generic-function)
  (set-n-stripes generic-function)
  (with-stripes macro)
  (stripe-start generic-function)
  (stripe-end generic-function)
  (set-input generic-function)
  (map-batches-for-model function)
  (do-batches-for-model macro))

(defgeneric max-n-stripes (object)
  (:documentation "The number of stripes with which the OBJECT is
  capable of dealing simultaneously. "))

(defgeneric set-max-n-stripes (max-n-stripes object)
  (:documentation "Allocate the necessary stuff to allow for
  MAX-N-STRIPES number of stripes to be worked with simultaneously in
  OBJECT. This is called when MAX-N-STRIPES is SETF'ed."))

(defsetf max-n-stripes (object) (store)
  `(set-max-n-stripes ,store ,object))

(defgeneric n-stripes (object)
  (:documentation "The number of stripes currently present in OBJECT.
  This is at most MAX-N-STRIPES."))

(defgeneric set-n-stripes (n-stripes object)
  (:documentation "Set the number of stripes (out of MAX-N-STRIPES)
  that are in use in OBJECT. This is called when N-STRIPES is
  SETF'ed."))

(defsetf n-stripes (object) (store)
  `(set-n-stripes ,store ,object))

(defmacro with-stripes (specs &body body)
  "Bind start and optionally end indices belonging to stripes in
  striped objects.

      (WITH-STRIPE ((STRIPE1 OBJECT1 START1 END1)
                    (STRIPE2 OBJECT2 START2)
                    ...)
       ...)"
  `(let* ,(mapcan (lambda (spec) (apply #'stripe-binding spec))
                  specs)
     ,@body))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun stripe-binding (stripe object start &optional end)
    (alexandria:with-gensyms (%stripe %object)
      `((,%stripe ,stripe)
        (,%object ,object)
        (,start (the index (stripe-start ,%stripe ,%object)))
        ,@(when end `((,end (the index (stripe-end ,%stripe ,%object)))))))))

(defgeneric stripe-start (stripe object)
  (:documentation "Return the start index of STRIPE in STRIPED-ARRAY
  of OBJECT."))

(defgeneric stripe-end (stripe object)
  (:documentation "Return the end index (exclusive) of STRIPE in
  STRIPED-ARRAY of OBJECT."))

(defgeneric set-input (instances model)
  (:documentation "Set INSTANCES as inputs in MODEL. SAMPLES is always
  a SEQUENCE of instances even for models not capable of batch
  operation. It sets N-STRIPES to (LENGTH INSTANCES) in a :BEFORE
  method."))

(defun map-batches-for-model (fn dataset model)
  "Call FN with batches of instances from DATASET suitable for MODEL.
  The number of instances in a batch is MAX-N-STRIPES of MODEL or less
  if there are no more instances left."
  (let ((sampler (if (typep dataset 'sequence)
                     (make-sequence-sampler dataset
                                            :max-n-samples (length dataset))
                     dataset)))
    (loop until (finishedp sampler) do
      (funcall fn (list-samples sampler (max-n-stripes model))))))

(defmacro do-batches-for-model ((batch (dataset model)) &body body)
  "Convenience macro over MAP-BATCHES-FOR-MODEL."
  `(map-batches-for-model (lambda (,batch) ,@body) ,dataset ,model))


;;;; Error counter

(defclass counter ()
  ((name :initform () :initarg :name :reader name)))

(defmethod initialize-instance :after ((counter counter) &key
                                       (prepend-name nil prepend-name-p)
                                       &allow-other-keys)
  (when prepend-name-p
    (push prepend-name (slot-value counter 'name))))

(defclass error-counter (counter)
  ((sum-errors
    :initform #.(flt 0) :reader sum-errors
    :documentation "The sum of errors.")
   (n-sum-errors
    :initform 0 :reader n-sum-errors
    :documentation "The total number of observations whose errors
    contributed to SUM-ERROR.")))

(defgeneric print-counter (counter stream))

(defmethod print-counter ((counter error-counter) stream)
  (multiple-value-bind (e c) (get-error counter)
    (if e
        (format stream "~,5E" e)
        (format stream "~A" e))
    (if (integerp c)
        (format stream " (~D)" c)
        (format stream " (~,2F)" c))))

(defclass misclassification-counter (error-counter)
  ((name :initform '("classification accuracy"))))

(defmethod print-counter ((counter misclassification-counter) stream)
  (multiple-value-bind (e c) (get-error counter)
    (if e
        (format stream "~,2F% (~D)"
                (* 100 (- 1 e)) c)
        (format stream "~A (~D)" e c))))

(defclass rmse-counter (error-counter)
  ((name :initform '("rmse"))))

(defgeneric add-error (counter err n)
  (:documentation "Add ERR to SUM-ERROR and N to N-SUM-ERRORS.")
  (:method ((counter error-counter) err n)
    (incf (slot-value counter 'sum-errors) err)
    (incf (slot-value counter 'n-sum-errors) n)))

(defgeneric reset-counter (counter)
  (:method ((counter error-counter))
    (with-slots (sum-errors n-sum-errors) counter
      (setf sum-errors #.(flt 0))
      (setf n-sum-errors 0))))

(defgeneric get-error (counter)
  (:method ((counter error-counter))
    (with-slots (sum-errors n-sum-errors) counter
      (values (if (zerop n-sum-errors)
                  0
                  (/ sum-errors n-sum-errors))
              n-sum-errors)))
  (:method ((counter rmse-counter))
    (multiple-value-bind (e n) (call-next-method)
      (values (sqrt e) n))))

(defmethod print-object ((counter counter) stream)
  (pprint-logical-block (stream ())
    (flet ((foo ()
             (when (slot-boundp counter 'name)
               (format stream "~{~A~^ ~:_~}: ~:_"
                       (alexandria:ensure-list (name counter))))
             (print-counter counter stream)))
      (if *print-escape*
          (print-unreadable-object (counter stream :type t)
            (foo))
          (foo))))
  counter)


;;;; Collecting errors

(defun add-measured-error (counter-and-measurer &rest args)
  (destructuring-bind (counter . measurer) counter-and-measurer
    (cond ((or (functionp measurer) (symbolp measurer))
           (multiple-value-call #'add-error counter (apply measurer args)))
          ((and (consp measurer) (eq :adder (car measurer)))
           (apply (cdr measurer) counter args))
          (t
           (error "Bad measurer ~S" measurer)))))

(defun apply-counters-and-measurers (counters-and-measurers &rest args)
  "Add the errors measured by the measurers to the counters."
  (map nil
       (lambda (counter-and-measurer)
         (apply #'add-measured-error counter-and-measurer args))
       counters-and-measurers)
  counters-and-measurers)

(defun collect-batch-errors (fn sampler learner counters-and-measurers)
  "Sample from SAMPLER until it runs out. Call FN with each batch of
  samples. COUNTERS-AND-MEASURERS is a sequence of conses of a counter
  and function. The function takes one parameter: a sequence of
  samples and is called after each call to FN. Measurers return two
  values: the cumulative error and the counter, suitable as the second
  and third argument to ADD-ERROR. Finally, return the counters.
  Return the list of counters from COUNTERS-AND-MEASURERS."
  (when counters-and-measurers
    (do-batches-for-model (samples (sampler learner))
      (funcall fn samples)
      (apply-counters-and-measurers counters-and-measurers samples learner)))
  (map 'list #'car counters-and-measurers))


;;;; Executors

(defgeneric map-over-executors (fn samples object)
  (:documentation "Divide SAMPLES between executors. And call FN with
  the samples and the executor for which the samples are.

  Some objects conflate function and call: the forward pass of a bpn
  computes output from inputs so it is like a function but it also
  doubles as a function call in the sense that the bpn (function)
  object changes state during the computation of the output. Hence not
  even the forward pass of a bpn is thread safe. There is also the
  restriction that all inputs must be of the same size.

  For example, if we have a function that builds bpn a for an input of
  a certain size, then we can create a factory that creates bpns for a
  particular call. The factory probably wants keep the weights the
  same though.

  Another possibility MAP-OVER-EXECUTORS allows is to parallelize
  execution.

  The default implementation simply calls FN with SAMPLES and
  OBJECT.")
  (:method (fn samples object)
    (funcall fn samples object)))

(defmacro do-executors ((samples object) &body body)
  `(map-over-executors (lambda (,samples ,object)
                         ,@body)
                       ,samples ,object))

(defclass trivial-cached-executor-mixin ()
  ((executor-cache :initform (make-hash-table :test #'equal)
                   :reader executor-cache))
  (:documentation ""))

(defun lookup-executor-cache (key cache)
  (gethash key (executor-cache cache)))

(defun insert-into-executor-cache (key cache value)
  (setf (gethash key (executor-cache cache)) value))

(defmethod map-over-executors (fn samples (c trivial-cached-executor-mixin))
  (trivially-map-over-executors fn samples c))

(defun trivially-map-over-executors (fn samples obj)
  (let ((executor-to-samples (make-hash-table)))
    (dolist (sample samples)
      (let ((executor (find-one-executor sample obj)))
        (push sample (gethash executor executor-to-samples))))
    (maphash (lambda (executor samples)
               (funcall fn samples executor))
             executor-to-samples)))

(defgeneric find-one-executor (sample obj)
  (:documentation "Called by TRIVIALLY-MAP-OVER-EXECUTORS.")
  (:method (sample obj)
    nil)
  (:method :around (sample obj)
    (or (call-next-method)
        obj)))

(defgeneric sample-to-executor-cache-key (sample object))
