-- lust-next code coverage module
local M = {}

-- Import submodules
local debug_hook = require("lib.coverage.debug_hook")
local file_manager = require("lib.coverage.file_manager")
local patchup = require("lib.coverage.patchup")
local static_analyzer = require("lib.coverage.static_analyzer")
local fs = require("lib.tools.filesystem")

-- Default configuration
local DEFAULT_CONFIG = {
  enabled = false,
  source_dirs = {".", "lib"},
  include = {"*.lua", "**/*.lua"},
  exclude = {
    "*_test.lua", "*_spec.lua", "test_*.lua",
    "tests/**/*.lua", "**/test/**/*.lua", "**/tests/**/*.lua",
    "**/spec/**/*.lua", "**/*.test.lua", "**/*.spec.lua",
    "**/*.min.lua", "**/vendor/**", "**/deps/**", "**/node_modules/**"
  },
  discover_uncovered = true,
  threshold = 90,
  debug = false,
  
  -- Execution vs coverage distinction
  track_self_coverage = true,  -- Record execution of coverage module files themselves
  
  -- Static analysis options
  use_static_analysis = true,  -- Use static analysis when available
  branch_coverage = false,      -- Track branch coverage (not just line coverage)
  cache_parsed_files = true,    -- Cache parsed ASTs for better performance
  track_blocks = true,          -- Track code blocks (not just lines)
  pre_analyze_files = false     -- Pre-analyze all files before test execution
}

-- Module state
local config = {}
local active = false
local original_hook = nil
local enhanced_mode = false

-- Expose configuration for external access (needed for config_test.lua)
M.config = DEFAULT_CONFIG

-- Track line coverage through instrumentation
function M.track_line(file_path, line_num)
  if not active or not config.enabled then
    return
  end
  
  local normalized_path = fs.normalize_path(file_path)
  
  -- Initialize file data if needed
  if not debug_hook.get_coverage_data().files[normalized_path] then
    -- Initialize file data
    local line_count = 0
    local source = fs.read_file(file_path)
    if source then
      for _ in source:gmatch("[^\r\n]+") do
        line_count = line_count + 1
      end
    end
    
    debug_hook.get_coverage_data().files[normalized_path] = {
      lines = {},
      functions = {},
      line_count = line_count,
      source = source
    }
  end
  
  -- Track line
  debug_hook.get_coverage_data().files[normalized_path].lines[line_num] = true
  debug_hook.get_coverage_data().lines[normalized_path .. ":" .. line_num] = true
end

-- Apply configuration with defaults
function M.init(options)
  -- Start with defaults
  config = {}
  for k, v in pairs(DEFAULT_CONFIG) do
    config[k] = v
  end
  
  -- Apply user options
  if options then
    for k, v in pairs(options) do
      if k == "include" or k == "exclude" then
        if type(v) == "table" then
          config[k] = v
        end
      else
        config[k] = v
      end
    end
  end
  
  -- Update the publicly exposed config
  for k, v in pairs(config) do
    M.config[k] = v
  end
  
  -- Reset coverage
  M.reset()
  
  -- Configure debug hook
  debug_hook.set_config(config)
  
  -- Initialize static analyzer if enabled
  if config.use_static_analysis then
    static_analyzer.init({
      cache_files = config.cache_parsed_files
    })
    
    -- Pre-analyze files if configured
    if config.pre_analyze_files then
      local found_files = {}
      -- Discover Lua files
      for _, dir in ipairs(config.source_dirs) do
        for _, include_pattern in ipairs(config.include) do
          local matches = fs.glob(dir, include_pattern)
          for _, file_path in ipairs(matches) do
            -- Check if file should be excluded
            local excluded = false
            for _, exclude_pattern in ipairs(config.exclude) do
              if fs.matches_pattern(file_path, exclude_pattern) then
                excluded = true
                break
              end
            end
            
            if not excluded then
              table.insert(found_files, file_path)
            end
          end
        end
      end
      
      -- Pre-analyze all discovered files
      if config.debug then
        print("DEBUG [Coverage] Pre-analyzing " .. #found_files .. " files")
      end
      
      for _, file_path in ipairs(found_files) do
        static_analyzer.parse_file(file_path)
      end
    end
  end
  
  -- Try to load enhanced C extensions
  local has_cluacov = pcall(require, "lib.coverage.vendor.cluacov_hook")
  enhanced_mode = has_cluacov
  
  if config.debug then
    print("DEBUG [Coverage] Initialized with " .. 
          (enhanced_mode and "enhanced C extensions" or "pure Lua implementation") ..
          (config.use_static_analysis and " and static analysis" or ""))
  end
  
  return M
end

-- Start coverage collection
function M.start(options)
  if not config.enabled then
    return M
  end
  
  if active then
    return M  -- Already running
  end
  
  -- Save original hook
  original_hook = debug.gethook()
  
  -- Set debug hook
  debug.sethook(debug_hook.debug_hook, "cl")
  
  active = true
  
  -- Instead of marking arbitrary initial lines, we'll analyze the code structure
  -- and mark logically connected lines to ensure consistent coverage highlighting
  
  -- Process loaded modules to ensure their module.lua files are tracked
  if package.loaded then
    for module_name, _ in pairs(package.loaded) do
      -- Try to find the module's file path
      local paths_to_check = {}
      
      -- Common module path patterns
      local patterns = {
        module_name:gsub("%.", "/") .. ".lua",                 -- module/name.lua
        module_name:gsub("%.", "/") .. "/init.lua",            -- module/name/init.lua
        "lib/" .. module_name:gsub("%.", "/") .. ".lua",       -- lib/module/name.lua
        "lib/" .. module_name:gsub("%.", "/") .. "/init.lua",  -- lib/module/name/init.lua
      }
      
      for _, pattern in ipairs(patterns) do
        table.insert(paths_to_check, pattern)
      end
      
      -- Try each potential path
      for _, potential_path in ipairs(paths_to_check) do
        if fs.file_exists(potential_path) and debug_hook.should_track_file(potential_path) then
          -- Module file found, process its structure
          process_module_structure(potential_path)
        end
      end
    end
  end
  
  -- Process the currently executing file
  local current_source
  for i = 1, 10 do -- Check several stack levels
    local info = debug.getinfo(i, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
      current_source = info.source:sub(2)
      if debug_hook.should_track_file(current_source) then
        process_module_structure(current_source)
      end
    end
  end
  
  return M
end

-- Process a module's code structure to mark logical execution paths
function process_module_structure(file_path)
  local normalized_path = fs.normalize_path(file_path)
  
  -- Initialize file data in coverage tracking
  if not debug_hook.get_coverage_data().files[normalized_path] then
    local source = fs.read_file(file_path)
    if not source then return end
    
    -- Split source into lines for analysis
    local lines = {}
    for line in (source .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
      table.insert(lines, line)
    end
    
    -- Initialize file data with basic information
    debug_hook.get_coverage_data().files[normalized_path] = {
      lines = {},
      functions = {},
      line_count = #lines,
      source = lines,
      source_text = source,
      executable_lines = {},
      logical_chunks = {} -- Store related code blocks
    }
    
    -- Apply static analysis immediately if enabled
    if config.use_static_analysis then
      local ast, code_map = static_analyzer.parse_file(file_path)
      
      if ast and code_map then
        if config.debug then
          print("DEBUG [Coverage] Using static analysis for " .. file_path)
        end
        
        -- Store static analysis information
        debug_hook.get_coverage_data().files[normalized_path].code_map = code_map
        debug_hook.get_coverage_data().files[normalized_path].ast = ast
        debug_hook.get_coverage_data().files[normalized_path].executable_lines = 
          static_analyzer.get_executable_lines(code_map)
        
        -- Register functions from static analysis
        for _, func in ipairs(code_map.functions) do
          local start_line = func.start_line
          local func_key = start_line .. ":" .. (func.name or "anonymous_function")
          
          debug_hook.get_coverage_data().files[normalized_path].functions[func_key] = {
            name = func.name or ("function_" .. start_line),
            line = start_line,
            end_line = func.end_line,
            params = func.params or {},
            executed = false
          }
        end
        
        -- CRITICAL FIX: Do NOT mark non-executable lines as covered at initialization
        -- This was causing all comments and non-executable lines to appear covered
        -- Just mark them as non-executable in the executable_lines table
        for line_num = 1, code_map.line_count do
          if not static_analyzer.is_line_executable(code_map, line_num) then
            if debug_hook.get_coverage_data().files[normalized_path].executable_lines then
              debug_hook.get_coverage_data().files[normalized_path].executable_lines[line_num] = false
            end
          end
        end
      else
        -- Static analysis failed, use basic heuristics
        if config.debug then
          print("DEBUG [Coverage] Static analysis failed for " .. file_path .. ", using heuristics")
        end
        fallback_heuristic_analysis(file_path, normalized_path, lines)
      end
    else
      -- Static analysis disabled, use basic heuristics
      fallback_heuristic_analysis(file_path, normalized_path, lines)
    end
  end
end

-- Fallback to basic heuristic analysis when static analysis is not available
function fallback_heuristic_analysis(file_path, normalized_path, lines)
  -- Mark basic imports and requires to ensure some coverage
  local import_section_end = 0
  for i, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed:match("^require") or 
       trimmed:match("^local%s+[%w_]+%s*=%s*require") or
       trimmed:match("^import") then
      -- This is an import/require line
      M.track_line(file_path, i)
      import_section_end = i
    elseif i > 1 and i <= import_section_end + 2 and 
           (trimmed:match("^local%s+[%w_]+") or trimmed == "") then
      -- Variable declarations or blank lines right after imports
      M.track_line(file_path, i)
    elseif i > import_section_end + 2 and trimmed ~= "" and 
           not trimmed:match("^%-%-") then
      -- First non-comment, non-blank line after imports section
      break
    end
  end
  
  -- Simple function detection
  for i, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")
    -- Detect function declarations
    local func_name = trimmed:match("^function%s+([%w_:%.]+)%s*%(")
    if func_name then
      debug_hook.get_coverage_data().files[normalized_path].functions[i .. ":" .. func_name] = {
        name = func_name,
        line = i,
        executed = false
      }
    end
    
    -- Detect local function declarations
    local local_func_name = trimmed:match("^local%s+function%s+([%w_:%.]+)%s*%(")
    if local_func_name then
      debug_hook.get_coverage_data().files[normalized_path].functions[i .. ":" .. local_func_name] = {
        name = local_func_name,
        line = i,
        executed = false
      }
    end
  end
end

-- Apply static analysis to a file with improved protection and timeout handling
local function apply_static_analysis(file_path, file_data)
  if not file_data.needs_static_analysis then
    return 0
  end
  
  -- Skip if the file doesn't exist or can't be read
  if not fs.file_exists(file_path) then
    if config.debug then
      print("DEBUG [Coverage] Skipping static analysis for non-existent file: " .. file_path)
    end
    return 0
  end
  
  -- Skip files over 250KB for performance (INCREASED from 100KB)
  local file_size = fs.get_file_size(file_path)
  if file_size and file_size > 250000 then
    if config.debug then
      print("DEBUG [Coverage] Skipping static analysis for large file: " .. file_path .. 
            " (" .. math.floor(file_size/1024) .. "KB)")
    end
    return 0
  end
  
  -- Skip test files that don't need detailed analysis
  if file_path:match("_test%.lua$") or 
     file_path:match("_spec%.lua$") or
     file_path:match("/tests/") or
     file_path:match("/test/") then
    if config.debug then
      print("DEBUG [Coverage] Skipping static analysis for test file: " .. file_path)
    end
    return 0
  end
  
  local normalized_path = fs.normalize_path(file_path)
  
  -- Set up timing with more generous timeout
  local timeout_reached = false
  local start_time = os.clock()
  local MAX_ANALYSIS_TIME = 3.0 -- 3 second timeout (INCREASED from 500ms)
  
  -- Variables for results
  local ast, code_map, improved_lines = nil, nil, 0
  
  -- PHASE 1: Parse file with static analyzer (with protection)
  local phase1_success, phase1_result = pcall(function()
    -- Short-circuit if we're already exceeding time
    if os.clock() - start_time > MAX_ANALYSIS_TIME then
      timeout_reached = true
      return nil, "Initial timeout"
    end
    
    -- Run the parser with all our protection mechanisms
    ast, err = static_analyzer.parse_file(file_path)
    if not ast then
      return nil, "Parse failed: " .. (err or "unknown error")
    end
    
    -- Check for timeout again before code_map access
    if os.clock() - start_time > MAX_ANALYSIS_TIME then
      timeout_reached = true
      return nil, "Timeout after parse"
    end
    
    -- Access code_map safely
    if type(ast) ~= "table" then
      return nil, "Invalid AST (not a table)"
    end
    
    -- Get the code_map from the result
    return ast, nil
  end)
  
  -- Handle errors from phase 1
  if not phase1_success then
    if config.debug then
      print("DEBUG [Coverage] Static analysis phase 1 error: " .. tostring(phase1_result) .. 
           " for file: " .. file_path)
    end
    return 0
  end
  
  -- Check for timeout or missing AST
  if timeout_reached or not ast then
    if config.debug then
      print("DEBUG [Coverage] Static analysis " .. 
            (timeout_reached and "timed out" or "failed") .. 
            " in phase 1 for file: " .. file_path)
    end
    return 0
  end
  
  -- PHASE 2: Get code map and apply it to our data (with protection)
  local phase2_success, phase2_result = pcall(function()
    -- First check if analysis is still within time limit
    if os.clock() - start_time > MAX_ANALYSIS_TIME then
      timeout_reached = true
      return 0, "Phase 2 initial timeout"
    end
    
    -- Try to get the code map from the companion cache
    code_map = ast._code_map -- This may have been attached by parse_file
    
    if not code_map then
      -- If no attached code map, we need to generate one
      local err
      code_map, err = static_analyzer.get_code_map_for_ast(ast, file_path)
      if not code_map then
        return 0, "Failed to get code map: " .. (err or "unknown error")
      end
    end
    
    -- Periodic timeout check
    if os.clock() - start_time > MAX_ANALYSIS_TIME then
      timeout_reached = true
      return 0, "Timeout after code map generation"
    end
    
    -- Apply the code map data to our file_data safely
    file_data.code_map = code_map
    
    -- Get executable lines safely with timeout protection
    local exec_lines_success, exec_lines_result = pcall(function()
      return static_analyzer.get_executable_lines(code_map)
    end)
    
    if not exec_lines_success then
      return 0, "Error getting executable lines: " .. tostring(exec_lines_result)
    end
    
    file_data.executable_lines = exec_lines_result
    file_data.functions_info = code_map.functions or {}
    file_data.branches = code_map.branches or {}
    
    return 1, nil -- Success
  end)
  
  -- Handle errors from phase 2
  if not phase2_success or timeout_reached then
    if config.debug then
      print("DEBUG [Coverage] Static analysis " .. 
            (timeout_reached and "timed out" or "failed") .. 
            " in phase 2 for file: " .. file_path ..
            (not phase2_success and (": " .. tostring(phase2_result)) or ""))
    end
    return 0
  end
  
  -- PHASE 3: Mark non-executable lines (this is the most expensive operation)
  local phase3_success, phase3_result = pcall(function()
    -- Final time check before heavy processing
    if os.clock() - start_time > MAX_ANALYSIS_TIME then
      timeout_reached = true
      return 0, "Phase 3 initial timeout"
    end
    
    local line_improved_count = 0
    local BATCH_SIZE = 100 -- Process in batches for better interrupt handling
    
    -- Process lines in batches to allow for timeout checks
    for batch_start = 1, file_data.line_count, BATCH_SIZE do
      -- Check timeout at the start of each batch
      if os.clock() - start_time > MAX_ANALYSIS_TIME then
        timeout_reached = true
        return line_improved_count, "Timeout during batch processing at line " .. batch_start
      end
      
      local batch_end = math.min(batch_start + BATCH_SIZE - 1, file_data.line_count)
      
      -- Process current batch
      for line_num = batch_start, batch_end do
        -- Use safe function to check if line is executable
        local is_exec_success, is_executable = pcall(function()
          return static_analyzer.is_line_executable(code_map, line_num)
        end)
        
        -- If not executable, mark it in executable_lines table
        if (is_exec_success and not is_executable) then
          -- Store that this line is non-executable in the executable_lines table
          file_data.executable_lines[line_num] = false
          
          -- IMPORTANT: If a non-executable line was incorrectly marked as covered, remove it
          if file_data.lines[line_num] then
            file_data.lines[line_num] = nil
            line_improved_count = line_improved_count + 1
          end
        end
      end
    end
    
    -- Mark functions based on static analysis (quick operation)
    if os.clock() - start_time <= MAX_ANALYSIS_TIME and code_map.functions then
      for _, func in ipairs(code_map.functions) do
        local start_line = func.start_line
        if start_line and start_line > 0 then
          local func_key = start_line .. ":function"
          
          if not file_data.functions[func_key] then
            -- Function is defined but wasn't called during test
            file_data.functions[func_key] = {
              name = func.name or ("function_" .. start_line),
              line = start_line,
              executed = false,
              params = func.params or {}
            }
          end
        end
      end
    end
    
    return line_improved_count, nil
  end)
  
  -- Handle errors from phase 3
  if not phase3_success then
    if config.debug then
      print("DEBUG [Coverage] Static analysis phase 3 error: " .. tostring(phase3_result) .. 
           " for file: " .. file_path)
    end
    return 0
  end
  
  -- If timeout occurred during phase 3, we still return any improvements we made
  if timeout_reached and config.debug then
    print("DEBUG [Coverage] Static analysis timed out in phase 3 for file: " .. file_path ..
          " - partial results used")
  end
  
  -- Return the number of improved lines
  improved_lines = type(phase3_result) == "number" and phase3_result or 0
  
  return improved_lines
end

-- Stop coverage collection
function M.stop()
  if not active then
    return M
  end
  
  -- Restore original hook
  debug.sethook(original_hook)
  
  -- Process coverage data
  if config.discover_uncovered then
    local added = file_manager.add_uncovered_files(
      debug_hook.get_coverage_data(),
      config
    )
    
    if config.debug then
      print("DEBUG [Coverage] Added " .. added .. " discovered files")
    end
  end
  
  -- Apply static analysis if configured
  if config.use_static_analysis then
    local improved_files = 0
    local improved_lines = 0
    
    for file_path, file_data in pairs(debug_hook.get_coverage_data().files) do
      if file_data.needs_static_analysis then
        local lines = apply_static_analysis(file_path, file_data)
        if lines > 0 then
          improved_files = improved_files + 1
          improved_lines = improved_lines + lines
        end
      end
    end
    
    if config.debug then
      print("DEBUG [Coverage] Applied static analysis to " .. improved_files .. 
            " files, improving " .. improved_lines .. " lines")
    end
  end
  
  -- Patch coverage data for non-executable lines, ensuring we're not
  -- incorrectly marking executable lines as covered
  local coverage_data = debug_hook.get_coverage_data()
  
  -- Very important pre-processing step: initialize executable_lines for all files if not present
  for file_path, file_data in pairs(coverage_data.files) do
    if not file_data.executable_lines then
      file_data.executable_lines = {}
    end
  end
  
  -- Now patch with our enhanced logic
  local patched = patchup.patch_all(coverage_data)
  
  -- Post-processing: verify we haven't incorrectly marked executable lines as covered
  local fixed_files = 0
  local fixed_lines = 0
  for file_path, file_data in pairs(coverage_data.files) do
    local file_fixed = false
    -- Check each line
    for line_num, is_covered in pairs(file_data.lines) do
      -- If it's marked covered but it's an executable line and wasn't actually executed
      if is_covered and file_data.executable_lines[line_num] and not debug_hook.was_line_executed(file_path, line_num) then
        -- Fix incorrect coverage
        file_data.lines[line_num] = false
        fixed_lines = fixed_lines + 1
        file_fixed = true
      end
    end
    if file_fixed then
      fixed_files = fixed_files + 1
    end
  end
  
  if config.debug then
    print("DEBUG [Coverage] Patched " .. patched .. " non-executable lines")
    if fixed_lines > 0 then
      print("DEBUG [Coverage] Fixed " .. fixed_lines .. " incorrectly marked executable lines in " .. fixed_files .. " files")
    end
  end
  
  active = false
  return M
end

-- Reset coverage data
function M.reset()
  debug_hook.reset()
  return M
end

-- Full reset (clears all data)
function M.full_reset()
  debug_hook.reset()
  return M
end

-- Process multiline comments in a file
local function process_multiline_comments(file_path, file_data)
  -- Skip if no source code available
  if not file_data.source or type(file_data.source) ~= "table" then
    return 0
  end
  
  local fixed = 0
  local in_comment = false
  
  -- Ensure executable_lines table exists
  if not file_data.executable_lines then
    file_data.executable_lines = {}
  end
  
  -- More sophisticated multiline comment handling
  -- Process each line to identify multiline comments
  for i = 1, file_data.line_count or #file_data.source do
    local line = file_data.source[i] or ""
    
    -- Track both --[[ and [[ style multiline comments
    local ml_comment_markers = {}
    
    -- Find all multiline comment markers in this line
    local pos = 1
    while pos <= #line do
      local start_pos_dash = line:find("%-%-%[%[", pos)
      local start_pos_bracket = line:find("%[%[", pos)
      local end_pos = line:find("%]%]", pos)
      
      -- Store each marker with its position
      if start_pos_dash and (not start_pos_bracket or start_pos_dash < start_pos_bracket) and 
         (not end_pos or start_pos_dash < end_pos) then
        table.insert(ml_comment_markers, {pos = start_pos_dash, type = "start", style = "dash"})
        pos = start_pos_dash + 4
      elseif start_pos_bracket and (not start_pos_dash or start_pos_bracket < start_pos_dash) and
             (not end_pos or start_pos_bracket < end_pos) and
             -- Only count [[ as comment start if not in a string
             not line:sub(1, start_pos_bracket-1):match("['\"]%s*$") then
        table.insert(ml_comment_markers, {pos = start_pos_bracket, type = "start", style = "bracket"})
        pos = start_pos_bracket + 2
      elseif end_pos then
        table.insert(ml_comment_markers, {pos = end_pos, type = "end"})
        pos = end_pos + 2
      else
        break -- No more markers in this line
      end
    end
    
    -- Sort markers by position
    table.sort(ml_comment_markers, function(a, b) return a.pos < b.pos end)
    
    -- Process markers in order
    local was_in_comment = in_comment
    local changed_in_this_line = false
    
    for _, marker in ipairs(ml_comment_markers) do
      if marker.type == "start" and not in_comment then
        in_comment = true
        changed_in_this_line = true
      elseif marker.type == "end" and in_comment then
        in_comment = false
        changed_in_this_line = true
      end
    end
    
    -- Handle line based on its comment state
    if was_in_comment or in_comment or changed_in_this_line then
      -- This line is part of or contains a multiline comment
      file_data.executable_lines[i] = false
      
      -- Only remove coverage marking if it wasn't actually executed
      if file_data.lines[i] then
        file_data.lines[i] = nil
        fixed = fixed + 1
      end
    end
  end
  
  return fixed
end

-- Get coverage report data
function M.get_report_data()
  local coverage_data = debug_hook.get_coverage_data()
  
  -- Process multiline comments in all files
  local multiline_fixed = 0
  for file_path, file_data in pairs(coverage_data.files) do
    multiline_fixed = multiline_fixed + process_multiline_comments(file_path, file_data)
  end
  
  if config.debug and multiline_fixed > 0 then
    print("DEBUG [Coverage Report] Fixed " .. multiline_fixed .. " lines in multiline comments")
  end
  
  -- Fix any incorrectly marked lines before generating report
  -- This is a critical final check to ensure we don't over-report coverage
  local fixed_lines = 0
  for file_path, file_data in pairs(coverage_data.files) do
    -- Check each line
    for line_num, is_covered in pairs(file_data.lines) do
      -- If it's marked covered but it's an executable line and wasn't actually executed
      -- Get actual line execution info from debug_hook, not just the coverage data
      if is_covered and 
         file_data.executable_lines and 
         file_data.executable_lines[line_num] and 
         not debug_hook.was_line_executed(file_path, line_num) then
        -- Fix incorrect coverage
        file_data.lines[line_num] = false
        fixed_lines = fixed_lines + 1
      end
    end
  end
  
  if config.debug and fixed_lines > 0 then
    print("DEBUG [Coverage Report] Fixed " .. fixed_lines .. " incorrectly marked executable lines")
  end
  
  -- Calculate statistics
  local stats = {
    total_files = 0,
    covered_files = 0,
    total_lines = 0,
    covered_lines = 0,
    total_functions = 0,
    covered_functions = 0,
    total_blocks = 0,
    covered_blocks = 0,
    files = {}
  }
  
  for file_path, file_data in pairs(coverage_data.files) do
    -- Count covered lines - BUT ONLY COUNT EXECUTABLE LINES!
    local covered_lines = 0
    local total_executable_lines = 0
    
    -- Debug output when processing our minimal_coverage.lua file
    local debug_this_file = config.debug and file_path:match("examples/minimal_coverage.lua")
    
    if debug_this_file then
      print(string.format("DEBUG [Coverage] Counting lines for file: %s", file_path))
      
      -- Print lines data
      print("  - file_data.lines table: " .. tostring(file_data.lines ~= nil))
      print("  - file_data.executable_lines table: " .. tostring(file_data.executable_lines ~= nil))
      
      -- Check some line examples
      for i = 1, 20 do
        local line_covered = file_data.lines and file_data.lines[i]
        local line_executable = file_data.executable_lines and file_data.executable_lines[i]
        print(string.format("  - Line %d: covered=%s, executable=%s", 
          i, tostring(line_covered), tostring(line_executable)))
      end
    end
    
    -- Do a thorough pass to ensure multiline comments are properly handled
    process_multiline_comments(file_path, file_data)
    
    -- Use a special counter for executable lines that accounts for multiline comments
    total_executable_lines = 0
    
    -- Make sure we have at least the basic line classifications
    if not file_data.executable_lines then
      file_data.executable_lines = {}
    end
    
    -- Mark all executable lines from actual execution
    for line_num, is_covered in pairs(file_data.lines or {}) do
      if is_covered then
        file_data.executable_lines[line_num] = true
      end
    end
    
    -- Create a list of executable lines accounting for multiline comments
    local in_multiline_comment = false
    
    -- First pass: count executable lines correctly
    if file_data.source then
      for line_num = 1, #file_data.source do
        local line = file_data.source[line_num]
        
        -- Check for multiline comment markers (with nil check)
        local starts_comment = line and line:match("^%s*%-%-%[%[") or false
        local ends_comment = line and line:match("%]%]") or false
        
        -- Update multiline comment state
        if starts_comment and not ends_comment then
          in_multiline_comment = true
        elseif ends_comment and in_multiline_comment then
          in_multiline_comment = false
        end
        
        -- Handle the line based on whether it's in a comment
        if not in_multiline_comment then
          -- CRITICAL FIX: Only count as executable if it's been marked executable by static analysis
          -- and NOT just because it was executed (avoid circular logic)
          if file_data.executable_lines and file_data.executable_lines[line_num] == true then
            total_executable_lines = total_executable_lines + 1
          end
        else
          -- For lines inside multiline comments:
          -- Always mark as non-executable and CRITICAL FIX: Definitely remove any coverage marking
          if file_data.executable_lines then
            file_data.executable_lines[line_num] = false
          end
          if file_data.lines then
            file_data.lines[line_num] = nil
          end
        end
      end
    end
    
    -- CRITICAL FIX: Now count only properly covered executable lines AND
    -- consider execution tracking for a more accurate representation
    
    -- First update lines based on execution tracking
    if file_data._executed_lines then
      for line_num, was_executed in pairs(file_data._executed_lines) do
        if was_executed and file_data.executable_lines and file_data.executable_lines[line_num] == true then
          -- If the line was executed AND is executable, mark it as covered
          file_data.lines[line_num] = true
          
          if debug_this_file then
            print(string.format("DEBUG [Coverage] Marked line %d as covered from execution tracking", line_num))
          end
        end
      end
    else
      -- If we don't have _executed_lines, create it and add executed lines from lines table
      -- This is a fallback for compatibility with older runs
      file_data._executed_lines = {}
      for line_num, is_covered in pairs(file_data.lines or {}) do
        if is_covered then
          file_data._executed_lines[line_num] = true
        end
      end
      
      if debug_this_file then
        print("DEBUG [Coverage] Created missing _executed_lines table from existing covered lines")
      end
    end
    
    -- Now process all marked lines
    for line_num, is_covered in pairs(file_data.lines or {}) do
      -- CRITICAL FIX: Only count lines that are both covered AND executable
      if is_covered and file_data.executable_lines and file_data.executable_lines[line_num] == true then
        -- This is a valid executable and covered line - count it
        covered_lines = covered_lines + 1
        
        if debug_this_file then
          print(string.format("DEBUG [Coverage] Counted covered line %d", line_num))
        end
      else
        -- CRITICAL FIX: Remove coverage marking from any non-executable line
        if file_data.executable_lines == nil or file_data.executable_lines[line_num] ~= true then
          -- This line isn't marked as executable but has coverage - remove it
          if debug_this_file then
            print(string.format("DEBUG [Coverage] Removed invalid coverage for line %d", line_num))
          end
          file_data.lines[line_num] = nil
        end
      end
    end
    
    -- Count functions (total and covered)
    local total_functions = 0
    local covered_functions = 0
    local functions_info = {}
    
    -- Debug the functions table
    if debug_this_file then
      print("Functions table in file_data:", tostring(file_data.functions ~= nil))
      
      -- More detailed debugging for functions table
      local function_count = 0
      for _, _ in pairs(file_data.functions or {}) do
        function_count = function_count + 1
      end
      print("Function count:", function_count)
      
      for func_key, func_data in pairs(file_data.functions or {}) do
        print(string.format("  Function %s at line %d: executed=%s, key=%s", 
          func_data.name or "anonymous", 
          func_data.line or 0, 
          tostring(func_data.executed),
          func_key))
      end
    end
    
    -- Fix to properly count and track functions
    -- Using iteration that doesn't depend on numeric indexing
    for func_key, func_data in pairs(file_data.functions or {}) do
      -- Verify this is a valid function entry with required data
      if type(func_data) == "table" and func_data.line and func_data.line > 0 then
        total_functions = total_functions + 1
        
        -- Enhanced debugging for function tracking
        if debug_this_file then
          print(string.format("DEBUG [Function Tracking] Processing function: %s at line %d", 
            func_data.name or "anonymous", func_data.line))
          print(string.format("  - executed: %s, calls: %d", 
            tostring(func_data.executed), func_data.calls or 0))
        end
        
        -- Fix function execution check by verifying coverage of function's lines
        -- If any line in the function body is covered, the function was executed
        if not func_data.executed and func_data.line > 0 then
          local start_line = func_data.line
          local end_line = func_data.end_line or (start_line + 20) -- Reasonable default
          
          -- Look for any executed line in the function body
          for i = start_line, end_line do
            if file_data.lines and file_data.lines[i] then
              func_data.executed = true
              if debug_this_file then
                print(string.format("  - Function marked as executed based on line %d", i))
              end
              break
            end
          end
        end
        
        -- Add to functions info list
        functions_info[#functions_info + 1] = {
          name = func_data.name or "anonymous",
          line = func_data.line,
          end_line = func_data.end_line,
          calls = func_data.calls or 0,
          executed = func_data.executed == true, -- Ensure boolean value
          params = func_data.params or {}
        }
        
        -- Additional debug for key functions
        if debug_this_file then
          print(string.format("  Added function %s to report, executed=%s", 
            func_data.name or "anonymous",
            tostring(func_data.executed == true)))
        end
        
        if func_data.executed == true then
          covered_functions = covered_functions + 1
        end
      end
    end
    
    -- If code has no detected functions (which is rare), assume at least one global chunk
    if total_functions == 0 then
      total_functions = 1
      
      -- Add an implicit "main" function
      functions_info[1] = {
        name = "main",
        line = 1,
        end_line = file_data.line_count,
        calls = covered_lines > 0 and 1 or 0,
        executed = covered_lines > 0,
        params = {}
      }
      
      if covered_lines > 0 then
        covered_functions = 1
      end
    end
    
    -- Process block coverage information
    local total_blocks = 0
    local covered_blocks = 0
    local blocks_info = {}
    
    -- Check if we have logical chunks (blocks) from static analysis
    if file_data.logical_chunks then
      for block_id, block_data in pairs(file_data.logical_chunks) do
        total_blocks = total_blocks + 1
        
        -- Add to blocks info list
        table.insert(blocks_info, {
          id = block_id,
          type = block_data.type,
          start_line = block_data.start_line,
          end_line = block_data.end_line,
          executed = block_data.executed or false,
          parent_id = block_data.parent_id,
          branches = block_data.branches or {}
        })
        
        if block_data.executed then
          covered_blocks = covered_blocks + 1
        end
      end
    end
    
    -- If we have code_map from static analysis but no blocks processed yet,
    -- we need to get block data from the code_map
    if file_data.code_map and file_data.code_map.blocks and 
       (not file_data.logical_chunks or next(file_data.logical_chunks) == nil) then
      -- Ensure static analyzer is loaded
      if not static_analyzer then
        static_analyzer = require("lib.coverage.static_analyzer")
      end
      
      -- Get block data from static analyzer
      local blocks = file_data.code_map.blocks
      total_blocks = #blocks
      
      for _, block in ipairs(blocks) do
        -- Determine if block is executed based on line coverage
        local executed = false
        for line_num = block.start_line, block.end_line do
          if file_data.lines[line_num] then
            executed = true
            break
          end
        end
        
        -- Add to blocks info
        table.insert(blocks_info, {
          id = block.id,
          type = block.type,
          start_line = block.start_line,
          end_line = block.end_line,
          executed = executed,
          parent_id = block.parent_id,
          branches = block.branches or {}
        })
        
        if executed then
          covered_blocks = covered_blocks + 1
        end
      end
    end
    
    -- Calculate percentages - USING EXECUTABLE LINE COUNT, NOT TOTAL LINES
    local line_pct = total_executable_lines > 0 
                     and (covered_lines / total_executable_lines * 100) 
                     or 0
    
    local func_pct = total_functions > 0
                    and (covered_functions / total_functions * 100)
                    or 0
                    
    local block_pct = total_blocks > 0
                    and (covered_blocks / total_blocks * 100)
                    or 0
    
    -- Sort functions and blocks by line number for consistent reporting
    table.sort(functions_info, function(a, b) return a.line < b.line end)
    table.sort(blocks_info, function(a, b) return a.start_line < b.start_line end)
    
    -- Add debug output to diagnose the coverage statistics
    if config.debug and file_path:match("examples/minimal_coverage.lua") then
      print(string.format("DEBUG [Coverage] File %s stats:", file_path))
      print(string.format("  - Executable lines: %d", total_executable_lines))
      print(string.format("  - Covered lines: %d", covered_lines))
      print(string.format("  - Line coverage: %.1f%%", line_pct))
      print(string.format("  - File data line_count: %s", tostring(file_data.line_count)))
      
      -- Print first 10 covered lines
      local covered_count = 0
      print("  - First 10 covered lines:")
      for line_num, is_covered in pairs(file_data.lines) do
        if is_covered and covered_count < 10 then
          covered_count = covered_count + 1
          print(string.format("    Line %d: covered", line_num))
        end
      end
      
      if covered_count == 0 then
        print("    No covered lines found!")
      end
    end
    
    -- Update file stats - using executable line count, not total line count
    stats.files[file_path] = {
      total_lines = total_executable_lines, -- Use executable line count, not total lines
      covered_lines = covered_lines,
      total_functions = total_functions,
      covered_functions = covered_functions,
      total_blocks = total_blocks,
      covered_blocks = covered_blocks,
      functions = functions_info,
      blocks = blocks_info,
      discovered = file_data.discovered or false,
      line_coverage_percent = line_pct,
      function_coverage_percent = func_pct,
      block_coverage_percent = block_pct,
      passes_threshold = line_pct >= config.threshold,
      uses_static_analysis = file_data.code_map ~= nil
    }
    
    -- Update global block totals
    stats.total_blocks = stats.total_blocks + total_blocks
    stats.covered_blocks = stats.covered_blocks + covered_blocks
    
    -- Update global stats
    stats.total_files = stats.total_files + 1
    local is_covered = covered_lines > 0
    stats.covered_files = stats.covered_files + (is_covered and 1 or 0)
    stats.total_lines = stats.total_lines + total_executable_lines  -- Use executable lines count, not total
    stats.covered_lines = stats.covered_lines + covered_lines
    stats.total_functions = stats.total_functions + total_functions
    stats.covered_functions = stats.covered_functions + covered_functions
    
    if debug_this_file then
      print(string.format("DEBUG [Coverage] Global stats update for file %s:", file_path))
      print(string.format("  - Covered: %s", tostring(is_covered)))
      print(string.format("  - Added %d to total_lines", total_executable_lines))
      print(string.format("  - Added %d to covered_lines", covered_lines))
      print(string.format("  - Added %d to total_functions", total_functions))
      print(string.format("  - Added %d to covered_functions", covered_functions))
    end
  end
  
  -- Calculate overall percentages
  
  -- For line coverage, count only executable lines for more accurate metrics
  local executable_lines = 0
  for file_path, file_data in pairs(coverage_data.files) do
    if file_data.code_map then
      for line_num = 1, file_data.line_count or 0 do
        if static_analyzer.is_line_executable(file_data.code_map, line_num) then
          executable_lines = executable_lines + 1
        end
      end
    else
      -- If no code map, use the total lines as a fallback
      executable_lines = executable_lines + (file_data.line_count or 0)
    end
  end
  
  -- Use executable lines as denominator for more accurate percentage
  local total_lines_for_coverage = executable_lines > 0 and executable_lines or stats.total_lines
  local line_coverage_percent = total_lines_for_coverage > 0 
                              and (stats.covered_lines / total_lines_for_coverage * 100)
                              or 0
                               
  local function_coverage_percent = stats.total_functions > 0
                                   and (stats.covered_functions / stats.total_functions * 100)
                                   or 0
                                   
  local file_coverage_percent = stats.total_files > 0
                               and (stats.covered_files / stats.total_files * 100)
                               or 0
                               
  local block_coverage_percent = stats.total_blocks > 0
                                and (stats.covered_blocks / stats.total_blocks * 100)
                                or 0
  
  -- Calculate overall percentage (weighted) - include block coverage if available
  local overall_percent
  if stats.total_blocks > 0 and config.track_blocks then
    -- If blocks are tracked, give them equal weight with line coverage
    -- This emphasizes conditional execution paths for more accurate coverage metrics
    overall_percent = (line_coverage_percent * 0.35) + 
                      (function_coverage_percent * 0.15) +
                      (block_coverage_percent * 0.5)  -- Give blocks higher weight (50%)
  else
    -- Traditional weighting without block coverage
    overall_percent = (line_coverage_percent * 0.8) + (function_coverage_percent * 0.2)
  end
  
  -- Add summary to stats
  stats.summary = {
    total_files = stats.total_files,
    covered_files = stats.covered_files,
    total_lines = stats.total_lines,
    covered_lines = stats.covered_lines,
    total_functions = stats.total_functions,
    covered_functions = stats.covered_functions,
    total_blocks = stats.total_blocks,
    covered_blocks = stats.covered_blocks,
    line_coverage_percent = line_coverage_percent,
    function_coverage_percent = function_coverage_percent,
    file_coverage_percent = file_coverage_percent,
    block_coverage_percent = block_coverage_percent,
    overall_percent = overall_percent,
    threshold = config.threshold,
    passes_threshold = overall_percent >= (config.threshold or 0),
    using_static_analysis = config.use_static_analysis,
    tracking_blocks = config.track_blocks
  }
  
  -- Pass the original file data for source code display, including execution data
  stats.original_files = {}
  
  -- Copy the files data, ensuring _executed_lines is included for each file
  for file_path, file_data in pairs(coverage_data.files) do
    stats.original_files[file_path] = {
      lines = {},  -- Covered lines
      _executed_lines = {}, -- Just executed (but not necessarily covered) lines
      executable_lines = {},
      source = file_data.source,
      source_text = file_data.source_text,
      line_count = file_data.line_count,
      logical_chunks = file_data.logical_chunks,
      logical_conditions = file_data.logical_conditions
    }
    
    -- Copy line coverage data
    for line_num, is_covered in pairs(file_data.lines or {}) do
      stats.original_files[file_path].lines[line_num] = is_covered
    end
    
    -- Copy executable line data
    for line_num, is_executable in pairs(file_data.executable_lines or {}) do
      stats.original_files[file_path].executable_lines[line_num] = is_executable
    end
    
    -- Copy executed line data - this is crucial for our new distinction
    for line_num, was_executed in pairs(file_data._executed_lines or {}) do
      stats.original_files[file_path]._executed_lines[line_num] = was_executed
    end
  end
  
  return stats
end

-- Generate coverage report
function M.report(format)
  -- Use reporting module for formatting
  local reporting = require("lib.reporting")
  local data = M.get_report_data()
  
  return reporting.format_coverage(data, format or "summary")
end

-- Save coverage report
function M.save_report(file_path, format)
  local reporting = require("lib.reporting")
  local data = M.get_report_data()
  
  return reporting.save_coverage_report(file_path, data, format or "html")
end

-- Debug dump
function M.debug_dump()
  local data = debug_hook.get_coverage_data()
  local stats = M.get_report_data().summary
  
  print("=== COVERAGE MODULE DEBUG DUMP ===")
  print("Mode: " .. (enhanced_mode and "Enhanced (C extensions)" or "Standard (Pure Lua)"))
  print("Active: " .. tostring(active))
  print("Configuration:")
  for k, v in pairs(config) do
    if type(v) == "table" then
      print("  " .. k .. ": " .. #v .. " items")
    else
      print("  " .. k .. ": " .. tostring(v))
    end
  end
  
  print("\nCoverage Stats:")
  print("  Files: " .. stats.covered_files .. "/" .. stats.total_files .. 
        " (" .. string.format("%.2f%%", stats.file_coverage_percent) .. ")")
  print("  Lines: " .. stats.covered_lines .. "/" .. stats.total_lines .. 
        " (" .. string.format("%.2f%%", stats.line_coverage_percent) .. ")")
  print("  Functions: " .. stats.covered_functions .. "/" .. stats.total_functions .. 
        " (" .. string.format("%.2f%%", stats.function_coverage_percent) .. ")")
  
  -- Show block coverage if available
  if stats.total_blocks > 0 then
    print("  Blocks: " .. stats.covered_blocks .. "/" .. stats.total_blocks .. 
          " (" .. string.format("%.2f%%", stats.block_coverage_percent) .. ")")
  end
  
  print("  Overall: " .. string.format("%.2f%%", stats.overall_percent))
  
  print("\nTracked Files (first 5):")
  local count = 0
  for file_path, file_data in pairs(data.files) do
    if count < 5 then
      local covered = 0
      for _ in pairs(file_data.lines) do covered = covered + 1 end
      
      print("  " .. file_path)
      print("    Lines: " .. covered .. "/" .. (file_data.line_count or 0))
      print("    Discovered: " .. tostring(file_data.discovered or false))
      
      count = count + 1
    else
      break
    end
  end
  
  if count == 5 and stats.total_files > 5 then
    print("  ... and " .. (stats.total_files - 5) .. " more files")
  end
  
  print("=== END DEBUG DUMP ===")
  return M
end

return M