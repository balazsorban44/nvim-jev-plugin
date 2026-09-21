--- Word spans and numbers lifted from the user's own utterance.
---
--- Port of `src/core/spans.js` from sdras/jev-webmcp-extension (Apache 2.0).
--- Header comment of the original, verbatim:
---
---   Jev picks; it never writes. So free-text and numeric arguments are turned
---   into a Choice over candidates lifted from the user's own words, and code
---   does the parsing. See docs.typesafe.ai "Pre-parsed value extraction".
---
--- Offsets here are 1-based byte offsets into the original string; `stop` is
--- the last byte of the token (the JS keeps an exclusive `end` instead).

local M = {}

-- JS: const TOKEN = /[\p{L}\p{N}$][\p{L}\p{N}'’\-./%]*/gu
--
-- DEVIATION (Lua patterns have no Unicode classes): every byte >= 0x80 counts
-- as a word byte, so any non-ASCII UTF-8 sequence joins a token. That is wider
-- than \p{L}\p{N} (it also admits e.g. non-ASCII punctuation) and it lets `’`
-- start a token, which the JS does not. For the ASCII editor requests this
-- plugin sees, the two agree exactly.
local TOKEN = "[%w$\128-\255][%w'%-./%%\128-\255]*"

-- JS: const TRAILING = /[.\-/'’]+$/u  — stripped from the end of every token.
-- `’` is U+2019; matching it as a whole string (not a byte set) keeps the
-- stripper from biting a byte out of some other multi-byte character.
local TRAILING = { ".", "-", "/", "'", "\226\128\153" }

-- Function words that never start or end a useful span (verbatim list).
local EDGE_STOPWORDS = {}
for word in ("a an the of to for and or with in at on from by me my i you we us it is are do does can could would please some any"):gmatch("%S+") do
  EDGE_STOPWORDS[word] = true
end

local function strip_trailing(word)
  local changed = true
  while changed do
    changed = false
    for _, ch in ipairs(TRAILING) do
      if #word >= #ch and word:sub(-#ch) == ch then
        word = word:sub(1, #word - #ch)
        changed = true
      end
    end
  end
  return word
end

--- All word tokens of `text`, with their byte offsets.
---@param text string
---@return { text: string, start: integer, stop: integer }[]
function M.tokenize(text)
  local tokens = {}
  local i = 1
  while i <= #text do
    local s, e = text:find(TOKEN, i)
    if not s then
      break
    end
    local word = strip_trailing(text:sub(s, e))
    if word ~= "" then
      tokens[#tokens + 1] = { text = word, start = s, stop = s + #word - 1 }
    end
    i = e + 1
  end
  return tokens
end

--- Contiguous word runs from `text`, shortest first, as the user typed them.
--- The span is sliced from the original string, so interior stopwords survive
--- ("files in the git" is a legal span); only the first and last token are
--- checked against EDGE_STOPWORDS.
---@param text string
---@param opts { max_words: integer?, limit: integer? }?
---@return string[]
function M.spans(text, opts)
  opts = opts or {}
  local max_words = opts.max_words or 5
  local limit = opts.limit or 120
  local tokens = M.tokenize(text or "")
  local seen, out = {}, {}
  for n = 1, max_words do
    for i = 1, #tokens - n + 1 do
      local first, last = tokens[i], tokens[i + n - 1]
      if not (EDGE_STOPWORDS[first.text:lower()] or EDGE_STOPWORDS[last.text:lower()]) then
        local span = text:sub(first.start, last.stop)
        local key = span:lower()
        if not seen[key] then
          seen[key] = true
          out[#out + 1] = span
          if #out >= limit then
            return out
          end
        end
      end
    end
  end
  return out
end

local UNITS = {
  zero = 0, one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9,
  ten = 10, eleven = 11, twelve = 12, thirteen = 13, fourteen = 14, fifteen = 15, sixteen = 16,
  seventeen = 17, eighteen = 18, nineteen = 19,
}
local TENS = { twenty = 20, thirty = 30, forty = 40, fifty = 50, sixty = 60, seventy = 70, eighty = 80, ninety = 90 }

-- JS PHRASES, in the same order (order matters: an earlier phrase claims its
-- span and a later overlapping one is rejected). Each regex is spelled out as
-- the alternatives it admits, longest first, so the leftmost-longest match wins
-- exactly as the regex engine's greedy optional groups do.
local PHRASES = {
  { value = 6, variants = { "half a dozen", "half dozen" } }, -- /\bhalf(?: a)? dozen\b/giu
  { value = 2, variants = { "a couple of", "a couple", "couple of", "couple" } }, -- /\b(?:a )?couple(?: of)?\b/giu
  { value = 12, variants = { "a dozen", "dozen" } }, -- /\b(?:a )?dozen\b/giu
}

-- JS \b is defined over ASCII \w = [A-Za-z0-9_].
local function word_byte(c)
  return c ~= nil and c:match("[%w_]") ~= nil
end

--- Numbers the user stated, as digits or words: `{ value, text }[]`.
--- Arithmetic stays in code.
---@param text string
---@return { value: number, text: string }[]
function M.numbers(text)
  text = text or ""
  local found, claimed = {}, {}

  -- Claimed intervals are half-open [start, stop): the JS overlap test.
  local function free(s, e)
    for _, c in ipairs(claimed) do
      if not (e <= c[1] or s >= c[2]) then
        return false
      end
    end
    return true
  end
  local function add(value, s, e)
    if value == nil or not free(s, e) then
      return
    end
    claimed[#claimed + 1] = { s, e }
    found[#found + 1] = { value = value, text = text:sub(s, e - 1), start = s, order = #found }
  end

  local lower = text:lower() -- ASCII-only lowering, so byte offsets still line up
  for _, phrase in ipairs(PHRASES) do
    local i = 1
    while i <= #lower do
      local matched = nil
      for _, v in ipairs(phrase.variants) do
        if lower:sub(i, i + #v - 1) == v then
          local before = i > 1 and lower:sub(i - 1, i - 1) or nil
          local after = (i + #v <= #lower) and lower:sub(i + #v, i + #v) or nil
          if not word_byte(before) and not word_byte(after) then
            matched = v
            break
          end
        end
      end
      if matched then
        add(phrase.value, i, i + #matched)
        i = i + #matched
      else
        i = i + 1
      end
    end
  end

  -- JS: /\d+(?:\.\d+)?/gu
  local i = 1
  while true do
    local s = text:find("%d", i)
    if not s then
      break
    end
    local digits = text:match("^%d+", s)
    local e = s + #digits
    local frac = text:match("^%.(%d+)", e)
    if frac then
      e = e + 1 + #frac
    end
    add(tonumber(text:sub(s, e - 1)), s, e)
    i = e
  end

  local tokens = M.tokenize(text)
  local t = 1
  while t <= #tokens do
    local word = tokens[t].text:lower()
    local dash = word:find("-", 1, true)
    local tens_word = dash and word:sub(1, dash - 1) or word
    local unit_word = dash and word:sub(dash + 1) or nil
    local has_unit = unit_word ~= nil and unit_word ~= ""
    if TENS[tens_word] then
      local nxt = tokens[t + 1] and tokens[t + 1].text:lower() or nil
      if has_unit and UNITS[unit_word] and UNITS[unit_word] < 10 then
        add(TENS[tens_word] + UNITS[unit_word], tokens[t].start, tokens[t].stop + 1)
      elseif not has_unit and nxt and UNITS[nxt] and UNITS[nxt] > 0 and UNITS[nxt] < 10 then
        add(TENS[tens_word] + UNITS[nxt], tokens[t].start, tokens[t + 1].stop + 1)
        t = t + 1
      elseif not has_unit then
        -- The JS writes TENS[word] in these two branches; with no dash, word ==
        -- tens_word, and a token can never end in "-" (TRAILING strips it), so
        -- the only difference would be an unreachable `undefined`.
        add(TENS[tens_word], tokens[t].start, tokens[t].stop + 1)
      end
    elseif UNITS[word] then
      add(UNITS[word], tokens[t].start, tokens[t].stop + 1)
    end
    t = t + 1
  end

  table.sort(found, function(a, b)
    if a.start ~= b.start then
      return a.start < b.start
    end
    return a.order < b.order -- table.sort is not stable; JS's Array#sort is
  end)

  local seen, out = {}, {}
  for _, n in ipairs(found) do
    if not seen[n.value] then
      seen[n.value] = true
      out[#out + 1] = { value = n.value, text = n.text }
    end
  end
  return out
end

return M
