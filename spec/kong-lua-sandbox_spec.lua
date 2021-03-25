local sandbox = require 'kong-lua-sandbox'

describe('kong-lua-sandbox.run', function()

  describe('when handling base cases', function()

    it('can run harmless strings', function()
      local r = sandbox.run("return 'hello'")
      assert.equal(r, 'hello')
    end)

    if sandbox.bytecode_blocked then
      it('rejects bytecode', function()
        local fn = function() end
        assert.error(function() sandbox.run(string.dump(fn)) end)
      end)
    else
      it('accepts bytecode (PUC Rio 5.1)', function()
        local fn = function() end
        assert.has.no.error(function() sandbox.run(string.dump(fn)) end)
      end)
    end

    it('has access to safe methods', function()
      assert.equal(10,      sandbox.run("return tonumber('10')"))
      assert.equal('HELLO', sandbox.run("return string.upper('hello')"))
      assert.equal(1,       sandbox.run("local a = {3,2,1}; table.sort(a); return a[1]"))
      assert.equal(10,      sandbox.run("return math.max(1,10)"))
    end)

    it('does not allow access to not-safe stuff', function()
      assert.error(function() sandbox.run('return setmetatable({}, {})') end)
      assert.error(function() sandbox.run('return string.rep("hello", 5)') end)
    end)

    it('does return multiple values', function()
      local result = { sandbox.run("return 'hello', 'world'") }
      assert.same({ 'hello', 'world' }, result)
    end)

    it('passes parameters to the code', function()
      assert.equal(sandbox.run("local a, b = ...; return a + b", {}, 1,2), 3)
    end)
  end)

  describe('when handling string.rep', function()
    it('does not allow pesky string:rep', function()
      assert.error(function() sandbox.run('return ("hello"):rep(5)') end)
    end)

    it('restores the value of string.rep', function()
      sandbox.run("")
      assert.equal('hellohello', string.rep('hello', 2))
    end)

    it('restores string.rep even if there is an error', function()
      assert.error(function() sandbox.run("error('foo')") end)
      assert.equal('hellohello', string.rep('hello', 2))
    end)

    it('allows providing string.rep on the environment', function()
      local env = { string = { rep = string.rep } }
      assert.equal('hellohello', sandbox.run("return string.rep('hello', 2)", { env = env }))
    end)
  end)


  describe('when the sandboxed code modifies the base environment', function()
    it('does not persist modifications of base modules on the global BASE_MODULE', function()
      sandbox.run("string.foo = 1")
      assert.is_nil(sandbox.run("return string.foo"))
    end)

    it('persists modifications of base modules on successive calls to the same protected function', function()
      local f = sandbox.protect("string.foo = (string.foo or 0) + 1; return string.foo")
      assert.equal(1, f())
      assert.equal(2, f())
      assert.equal(3, f())
    end)

    it('does not persist modifications of base functions on the global BASE_MODULE', function()
      sandbox.run('error = function() end')
      assert.error(function() sandbox.run("error('this should be raised')") end)
    end)

    it('persists modifications of base functions on successive calls to the same protected function', function()
      local f = sandbox.protect("error = (type(error) == 'number' and error or 0) + 1; return error")
      assert.equal(1, f())
      assert.equal(2, f())
      assert.equal(3, f())
    end)

    it('does not persist modification to provided env modules on the global BASE_MODULE', function()
      local env = { foo = { bar = 'baz' }}
      sandbox.run('foo.bar = 1', { env=env })
      assert.equal('baz', env.foo.bar)
    end)

    it('persists modifications of base functions on successive calls to the same protected function', function()
      local f = sandbox.protect("error = (type(error) == 'number' and error or 0) + 1; return error")
      assert.equal(1, f())
      assert.equal(2, f())
      assert.equal(3, f())
    end)



    it('does not persist modification to provided env functions on the global BASE_MODULE', function()
      local env = {['next'] = 'hello'}
      sandbox.run('next = "bye"', { env=env })
      assert.equal(env['next'], 'hello')
    end)

    it('does not persist partial modifications to provided env modules on the global BASE_MODULE', function()
      local env = { math = { e = 2.71828 } } -- Euler's number
      local similar_numbers = function(a, b)
        return math.abs(a - b) < 0.01
      end
      -- we have modified math by adding math.e but math.log is still available
      assert.is_true(similar_numbers(1, sandbox.run('return math.log(math.e)', { env=env })))
    end)
  end)


  if sandbox.quota_supported then
    describe('when given infinite loops', function()
      it('throws an error with infinite loops', function()
        assert.error(function() sandbox.run("while true do end") end)
      end)

      it('restores string.rep even after a while true', function()
        assert.error(function() sandbox.run("while true do end") end)
        assert.equal('hellohello', string.rep('hello', 2))
      end)

      it('accepts a quota param', function()
        assert.has_no.errors(function() sandbox.run("for i=1,100 do end") end)
        assert.error(function() sandbox.run("for i=1,100 do end", {quota = 20}) end)
      end)

      it('does not use quotes if the quote param is false', function()
        assert.has_no.errors(function() sandbox.run("for i=1,1000000 do end", {quota = false}) end)
      end)
    end)
  else
    it('throws an error when trying to use the quota option in an unsupported environment (LuaJIT)', function()
      assert.error(function() sandbox.run("", {quota = 20}) end)
    end)
  end


  describe('when given an env option', function()
    it('is available on the sandboxed env as the _G variable', function()
      local env = {foo = 1}
      assert.equal(1, sandbox.run("return foo", {env = env}))
      assert.equal(1, sandbox.run("return _G.foo", {env = env}))
    end)

    it('does not hide base env', function()
      assert.equal('HELLO', sandbox.run("return string.upper(foo)", {env = {foo = 'hello'}}))
    end)

    it('cannot modify the env', function()
      local env = {foo = 1}
      sandbox.run("foo = 2", {env = env})
      assert.equal(env.foo, 1)
    end)

    it('uses the env metatable, if it exists', function()
      local env1 = { foo = 1 }
      local env2 = { bar = 2 }
      setmetatable(env2, { __index = env1 })
      assert.equal(3, sandbox.run("return foo + bar", { env = env2 }))
    end)

    it('can override the base env', function()
      local env = { tostring = function(x) return "hello " .. x end }
      assert.equal("hello peter", sandbox.run("return tostring('peter')", { env = env }))
    end)

    it('can override the base env with false', function()
      local env = { tostring = false }
      assert.is_false(sandbox.run("return tostring", { env = env }))
    end)

    it('can override _G', function()
      local env = { _G = "foo" }
      assert.equals("foo", sandbox.run("return _G", { env = env }))
    end)

    it('can have recursive references to the environment', function()
      local env = {}
      env.recursive = env
      assert.is_true(sandbox.run("return recursive.recursive == recursive", { env = env }))
    end)

    it('can have deeper recursive references', function()
      local env = { mylib = {} }
      env.mylib.recursive = env.mylib
      assert.is_true(sandbox.run("return mylib.recursive == mylib", { env = env }))
    end)

  end)

end)
