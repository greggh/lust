-- Example demonstrating async testing features
package.path = "../?.lua;" .. package.path
local lust_next = require("lust-next")

-- Import the test functions
local describe, it, expect = lust_next.describe, lust_next.it, lust_next.expect
local it_async = lust_next.it_async
local async = lust_next.async
local await = lust_next.await
local wait_until = lust_next.wait_until

-- Use the async module directly if we need more control
local async_module = package.loaded["src.async"]

-- Set a default timeout for all async tests (in milliseconds)
if async_module then
  async_module.set_timeout(2000) -- 2 seconds
end

-- Simulate an asynchronous API
local AsyncAPI = {}

-- Simulate a delayed response
function AsyncAPI.fetch_data(callback, delay)
  delay = delay or 100 -- default delay
  
  -- In a real app, this might be a network request or database query
  local timer_id = nil
  
  -- Create our own setTimeout simulation
  local start_time = os.clock() * 1000
  local function check_timer()
    if os.clock() * 1000 - start_time >= delay then
      callback({ status = "success", data = { value = 42 } })
      return true
    end
    return false
  end
  
  return {
    -- Function to check if the request is complete (for testing)
    is_complete = check_timer,
    
    -- Simulate cancellation
    cancel = function()
      -- Would cancel the request in a real implementation
    end
  }
end

-- Example that demonstrates how to test async code
describe("Async Testing Demo", function()
  
  describe("Basic async/await", function()
    it_async("waits for a specified time", function()
      local start_time = os.clock()
      
      -- Wait for 100ms
      await(100)
      
      local elapsed = (os.clock() - start_time) * 1000
      expect(elapsed).to.be.truthy()
      expect(elapsed >= 95).to.be.truthy() -- Allow for small timing differences
    end)
    
    it_async("can perform assertions after waiting", function()
      local value = 0
      
      -- Simulate async operation that changes a value after 50ms
      local start_time = os.clock() * 1000
      
      -- In a real app, this might be a callback from an event or API
      local function check_value_updated()
        if os.clock() * 1000 - start_time >= 50 then
          value = 42
          return true
        end
        return false
      end
      
      -- Wait until the condition is true or timeout
      wait_until(check_value_updated, 200)
      
      -- Now we can make assertions on the updated value
      expect(value).to.equal(42)
    end)
  end)
  
  describe("Simulated API testing", function()
    it_async("can test callbacks with await", function()
      local result = nil
      
      -- Start the async operation
      local request = AsyncAPI.fetch_data(function(data)
        result = data
      end, 150)
      
      -- Wait until the request completes
      wait_until(request.is_complete, 500, 10)
      
      -- Now we can make assertions on the result
      expect(result).to.exist()
      expect(result.status).to.equal("success")
      expect(result.data.value).to.equal(42)
    end)
    
    it_async("demonstrates timeout behavior", function()
      local result = nil
      local did_timeout = false
      
      -- This test sets a very short timeout that should cause the test to fail
      -- but we catch the error to demonstrate the behavior
      
      -- Start an async operation that will take too long (300ms)
      local request = AsyncAPI.fetch_data(function(data)
        result = data
      end, 300)
      
      -- Try to wait with a short timeout (50ms)
      local success = pcall(function()
        wait_until(request.is_complete, 50, 10)
      end)
      
      -- The wait should have timed out
      expect(success).to.equal(false)
      expect(result).to.equal(nil) -- The callback shouldn't have been called yet
      
      -- Clean up (cancel the request in a real implementation)
      request.cancel()
    end)
  end)
  
  describe("Using async() directly", function()
    it("runs an async test with custom timeout", async(function()
      local start_time = os.clock()
      
      await(100)
      
      local elapsed = (os.clock() - start_time) * 1000
      expect(elapsed >= 95).to.be.truthy()
    end, 1000)) -- 1 second timeout
    
    -- Nested async calls
    it("supports nested async operations", async(function()
      local value = 0
      
      -- First async operation
      await(50)
      value = value + 1
      
      -- Second async operation
      await(50)
      value = value + 1
      
      -- Final assertion
      expect(value).to.equal(2)
    end))
  end)
end)

print("\nAsync testing features demo completed!")