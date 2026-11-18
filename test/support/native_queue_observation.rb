# Uncached cross-process observation is qualified by the review regression.
module NativeQueueObservation
  module_function
  def jobs(ids)
    SolidQueue::Job.uncached { SolidQueue::Job.where(id: ids).to_a }
  end
end
