--!native
--[=[
	Lexical scanner for creating a sequence of tokens from Lua source code.
	This is a heavily modified and Roblox-optimized version of
	the original Penlight Lexer module:
		https://github.com/stevedonovan/Penlight
	Authors:
		stevedonovan <https://github.com/stevedonovan> ----------- Original Penlight lexer author
		ryanjmulder <https://github.com/ryanjmulder> ------------- Penlight lexer contributer
		mpeterv <https://github.com/mpeterv> --------------------- Penlight lexer contributer
		Tieske <https://github.com/Tieske> ----------------------- Penlight lexer contributer
		boatbomber <https://github.com/boatbomber> --------------- Roblox port, added builtin token,
		                                                           added patterns for incomplete syntax, bug fixes,
		                                                           behavior changes, token optimization, thread optimization
		                                                           Added lexer.navigator() for non-sequential reads
		Sleitnick <https://github.com/Sleitnick> ----------------- Roblox optimizations
		howmanysmall <https://github.com/howmanysmall> ----------- Lua + Roblox optimizations

	List of possible tokens:
		- iden
		- keyword
		- builtin
		- string
		- number
		- comment
		- operator
--]=]

local lexer = {}

const Prefix, Suffix, Cleaner = "^[%c%s]*", "[%c%s]*", "[%c%s]+"
const UNICODE = "[%z\x01-\x7F\xC2-\xF4][\x80-\xBF]+"
const NUMBER_A = "0[xX][%da-fA-F_]+"
const NUMBER_B = "0[bB][01_]+"
const NUMBER_C = "%d+%.?%d*[eE][%+%-]?%d+"
const NUMBER_D = "%d+[%._]?[%d_eE]*"
const OPERATORS = "[:;<>/~%*%(%)%-={},%.#%^%+%%]+"
const BRACKETS = "[%[%]]+"
const IDEN = "[%a_][%w_]*"
const STRING_EMPTY = "(['\"])%1"
const STRING_PLAIN = "(['\"])[^\n]-([^\\]%1)"
const STRING_INCOMP_A = "(['\"]).-\n"
const STRING_INCOMP_B = "(['\"])[^\n]*"
const STRING_MULTI = "%[(=*)%[.-%]%1%]"
const STRING_MULTI_INCOMP = "%[=*%[.-.*"
const COMMENT_MULTI = "%-%-%[(=*)%[.-%]%1%]"
const COMMENT_MULTI_INCOMP = "%-%-%[=*%[.-.*"
const COMMENT_PLAIN = "%-%-.-\n"
const COMMENT_INCOMP = "%-%-.*"

const lang = require(script.language)
const lua_keyword = lang.keyword
const lua_builtin = lang.builtin
const lua_libraries = lang.libraries

const lua_matches = {
	{ Prefix .. IDEN .. Suffix, "var" },

	{ Prefix .. NUMBER_A .. Suffix, "number" },
	{ Prefix .. NUMBER_B .. Suffix, "number" },
	{ Prefix .. NUMBER_C .. Suffix, "number" },
	{ Prefix .. NUMBER_D .. Suffix, "number" },

	{ Prefix .. STRING_EMPTY .. Suffix, "string" },
	{ Prefix .. STRING_PLAIN .. Suffix, "string" },
	{ Prefix .. STRING_INCOMP_A .. Suffix, "string" },
	{ Prefix .. STRING_INCOMP_B .. Suffix, "string" },
	{ Prefix .. STRING_MULTI .. Suffix, "string" },
	{ Prefix .. STRING_MULTI_INCOMP .. Suffix, "string" },

	{ Prefix .. COMMENT_MULTI .. Suffix, "comment" },
	{ Prefix .. COMMENT_MULTI_INCOMP .. Suffix, "comment" },
	{ Prefix .. COMMENT_PLAIN .. Suffix, "comment" },
	{ Prefix .. COMMENT_INCOMP .. Suffix, "comment" },

	{ Prefix .. OPERATORS .. Suffix, "operator" },
	{ Prefix .. BRACKETS .. Suffix, "operator" },

	{ Prefix .. UNICODE .. Suffix, "iden" },

	{ "^.", "iden" },
}

--- Create a plain token iterator from a string.
-- @tparam string s a string.

function lexer.scan(s: string)
	-- local startTime = os.clock()
	lexer.finished = false

	local index = 1
	local sz = #s
	local p1, p2, p3, pT = "", "", "", ""

	return function()
		if index <= sz then
			for _, m in lua_matches do
				local i1, i2 = string.find(s, m[1], index)
				if i1 then
					local tok = string.sub(s, i1, i2)
					index = i2 + 1
					lexer.finished = index > sz
					--if lexer.finished then
					--	print((os.clock()-startTime)*1000, "ms")
					--end

					local t = m[2]
					local t2 = t

					-- Process t into t2
					if t == "var" then
						-- Since we merge spaces into the tok, we need to remove them
						-- in order to check the actual word it contains
						local cleanTok = string.gsub(tok, Cleaner, "")

						if lua_keyword[cleanTok] then
							t2 = "keyword"
						elseif lua_builtin[cleanTok] then
							t2 = "builtin"
						else
							t2 = "iden"
						end

						if string.find(p1, "%.[%s%c]*$") and pT ~= "comment" then
							-- The previous was a . so we need to special case indexing things
							local parent = string.gsub(p2, Cleaner, "")
							local lib = lua_libraries[parent]
							if lib and lib[cleanTok] and not string.find(p3, "%.[%s%c]*$") then
								-- Indexing a builtin lib with existing item, treat as a builtin
								t2 = "builtin"
							else
								-- Indexing a non builtin, can't be treated as a keyword/builtin
								t2 = "iden"
							end
							-- print("indexing",parent,"with",cleanTok,"as",t2)
						end
					end

					-- Record last 3 tokens for the indexing context check
					p3 = p2
					p2 = p1
					p1 = tok
					pT = t2
					return t2, tok
				end
			end
			-- No matches
			return nil
		end
		-- Reached end
		return nil
	end
end

function lexer.navigator()
	local nav = {
		Source = "",
		TokenCache = table.create(50),

		_RealIndex = 0,
		_UserIndex = 0,
		_ScanThread = nil,
	}

	function nav:Destroy()
		self.Source = nil
		self._RealIndex = nil
		self._UserIndex = nil
		self.TokenCache = nil
		self._ScanThread = nil
	end

	function nav:SetSource(SourceString)
		self.Source = SourceString

		self._RealIndex = 0
		self._UserIndex = 0
		table.clear(self.TokenCache)

		self._ScanThread = coroutine.create(function()
			for Token, Src in lexer.scan(self.Source) do
				self._RealIndex += 1
				self.TokenCache[self._RealIndex] = { Token, Src }
				coroutine.yield(Token, Src)
			end
		end)
	end

	function nav.Next()
		nav._UserIndex += 1

		if nav._RealIndex >= nav._UserIndex then
			-- Already scanned, return cached
			return table.unpack(nav.TokenCache[nav._UserIndex])
		else
			if coroutine.status(nav._ScanThread) == "dead" then
				-- Scan thread dead
				return
			else
				local success, token, src = coroutine.resume(nav._ScanThread)
				if success and token then
					-- Scanned new data
					return token, src
				else
					-- Lex completed
					return
				end
			end
		end
	end

	function nav.Peek(PeekAmount)
		local GoalIndex = nav._UserIndex + PeekAmount

		if nav._RealIndex >= GoalIndex then
			-- Already scanned, return cached
			if GoalIndex > 0 then
				return table.unpack(nav.TokenCache[GoalIndex])
			else
				-- Invalid peek
				return
			end
		else
			if coroutine.status(nav._ScanThread) == "dead" then
				-- Scan thread dead
				return
			else
				local IterationsAway = GoalIndex - nav._RealIndex

				local success, token, src = nil, nil, nil

				for _ = 1, IterationsAway do
					success, token, src = coroutine.resume(nav._ScanThread)
					if not (success or token) then
						-- Lex completed
						break
					end
				end

				return token, src
			end
		end
	end

	return nav
end

return lexer
