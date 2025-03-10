-- Basic usage example for lust-next
local lust = require("lust-next")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- A simple calculator module to test
local calculator = {
  add = function(a, b) return a + b end,
  subtract = function(a, b) return a - b end,
  multiply = function(a, b) return a * b end,
  divide = function(a, b)
    if b == 0 then error("Cannot divide by zero") end
    return a / b
  end
}

-- Test suite
describe("Calculator", function()
  -- Setup that runs before each test
  lust.before(function()
    print("Setting up test...")
  end)
  
  -- Cleanup that runs after each test
  lust.after(function()
    print("Cleaning up test...")
  end)
  
  describe("addition", function()
    it("adds two positive numbers", function()
      expect(calculator.add(2, 3)).to.equal(5)
    end)
    
    it("adds a positive and a negative number", function()
      expect(calculator.add(2, -3)).to.equal(-1)
    end)
  end)
  
  describe("subtraction", function()
    it("subtracts two numbers", function()
      expect(calculator.subtract(5, 3)).to.equal(2)
    end)
  end)
  
  describe("multiplication", function()
    it("multiplies two numbers", function()
      expect(calculator.multiply(2, 3)).to.equal(6)
    end)
  end)
  
  describe("division", function()
    it("divides two numbers", function()
      expect(calculator.divide(6, 3)).to.equal(2)
    end)
    
    it("throws error when dividing by zero", function()
      expect(function() calculator.divide(5, 0) end).to.fail.with("Cannot divide by zero")
    end)
  end)
end)

-- Output will show nested describe blocks and test results with colors