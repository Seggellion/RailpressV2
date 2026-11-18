module AdministrationTestSupport
  def with_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name) do |*args, **kwargs, &block|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &block) : replacement
    end
    yield
  ensure
    target.define_singleton_method(name, original)
  end
end
