module Portability
  module Context
    module_function
    KEY = :portability_worker
    def with(batch, token)
      raise Imports::Conflict, "Nested import context." if ActiveSupport::IsolatedExecutionState[KEY]
      ActiveSupport::IsolatedExecutionState[KEY] = [ batch.id, token ]
      installed = true
      yield
    ensure
      ActiveSupport::IsolatedExecutionState.delete(KEY) if installed
    end
    def require!(batch)
      context = ActiveSupport::IsolatedExecutionState[KEY]
      raise Identity::Capabilities::Denied unless context && context == [ batch.id, batch.lease_token ] && %w[staging activating reversing].include?(batch.state)
      raise Imports::Conflict, "Worker claim expired; reconcile before retrying." unless Worker.lease_valid?(batch)
    end
    def require_item!(item)
      row = ImportItem.lock.find(item.id); batch = ImportBatch.lock.find(row.import_batch_id)
      require!(batch)
      raise Imports::Conflict, "Item is not processing." unless row.state == "processing"
      item
    end
    def staged_content?(id)
      context = ActiveSupport::IsolatedExecutionState[KEY]
      return false unless context
      batch = ImportBatch.find(context[0]); require!(batch)
      batch.import_items.where(kind: "content", target_id: id, state: %w[staged matched activated]).exists?
    end
  end
end
