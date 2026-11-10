-- Expressions in a design's numbers: "width/2 - wall", "holes > 0 ? 3 : 0",
-- "sin(angle) * r". Parsed once per string (cached), evaluated against the
-- design's parameters and variables. Trigonometry is in degrees, as
-- OpenSCAD's is; true/false are 1/0.

local M = {}

local FUNCS: { [string]: (...number) -> number } = {
	sin = function(a) return math.sin(math.rad(a)) end,
	cos = function(a) return math.cos(math.rad(a)) end,
	tan = function(a) return math.tan(math.rad(a)) end,
	asin = function(a) return math.deg(math.asin(a)) end,
	acos = function(a) return math.deg(math.acos(a)) end,
	atan = function(a) return math.deg(math.atan(a)) end,
	atan2 = function(y, x) return math.deg(math.atan2(y, x)) end,
	sqrt = function(a) return math.sqrt(a) end,
	abs = function(a) return math.abs(a) end,
	floor = function(a) return math.floor(a) end,
	ceil = function(a) return math.ceil(a) end,
	round = function(a) return math.floor(a + 0.5) end,
	min = function(...) return math.min(...) end,
	max = function(...) return math.max(...) end,
	pow = function(a, b) return a ^ b end,
	exp = function(a) return math.exp(a) end,
	ln = function(a) return math.log(a) end,
	log = function(a) return math.log10(a) end,
	clamp = function(x, a, b) return math.clamp(x, math.min(a, b), math.max(a, b)) end,
	sign = function(a) return if a > 0 then 1 elseif a < 0 then -1 else 0 end,
}

local CONSTS: { [string]: number } = { pi = math.pi, PI = math.pi, ["true"] = 1, ["false"] = 0 }

type Tok = { k: string, v: any }

local function lex(s: string): { Tok }
	local out: { Tok } = {}
	local i, n = 1, #s
	while i <= n do
		local c = string.sub(s, i, i)
		if string.find(c, "%s") then
			i += 1
		elseif string.find(c, "[%d%.]") then
			local num = string.match(s, "^%d*%.?%d+[eE][%+%-]?%d+", i) or string.match(s, "^%d*%.?%d*", i)
			local v = tonumber(num)
			if v == nil then
				error(`bad number at "{string.sub(s, i)}"`, 0)
			end
			table.insert(out, { k = "num", v = v })
			i += #num
		elseif string.find(c, "[%a_$]") then
			local name = string.match(s, "^[%a_$][%w_$]*", i) :: string
			table.insert(out, { k = "id", v = name })
			i += #name
		else
			local two = string.sub(s, i, i + 1)
			if two == "<=" or two == ">=" or two == "==" or two == "!=" or two == "&&" or two == "||" then
				table.insert(out, { k = "op", v = two })
				i += 2
			elseif string.find(c, "[%+%-%*/%%%^%(%),%?:<>!]") then
				table.insert(out, { k = "op", v = c })
				i += 1
			else
				error(`unexpected "{c}"`, 0)
			end
		end
	end
	table.insert(out, { k = "end", v = nil })
	return out
end

-- An AST node is a function of the environment.
type Fn = (env: { [string]: number }) -> number

local function parse(s: string): Fn
	local toks = lex(s)
	local pos = 1
	local function peek(): Tok
		return toks[pos]
	end
	local function take(): Tok
		local t = toks[pos]
		pos += 1
		return t
	end
	local function expect(op: string)
		local t = take()
		if t.k ~= "op" or t.v ~= op then
			error(`expected "{op}" in "{s}"`, 0)
		end
	end
	local ternary: () -> Fn
	local function primary(): Fn
		local t = take()
		if t.k == "num" then
			local v = t.v
			return function()
				return v
			end
		elseif t.k == "id" then
			local name = t.v :: string
			local nt = peek()
			if nt.k == "op" and nt.v == "(" then
				take()
				local args: { Fn } = {}
				local close = peek()
				if not (close.k == "op" and close.v == ")") then
					while true do
						table.insert(args, ternary())
						local sep = peek()
						if sep.k == "op" and sep.v == "," then
							take()
						else
							break
						end
					end
				end
				expect(")")
				local f = FUNCS[name]
				if not f then
					error(`unknown function {name}()`, 0)
				end
				return function(env)
					local vals = table.create(#args)
					for i, a in args do
						vals[i] = a(env)
					end
					return f(table.unpack(vals))
				end
			end
			local const = CONSTS[name]
			if const then
				return function()
					return const
				end
			end
			return function(env)
				local v = env[name]
				if v == nil then
					error(`unknown name "{name}"`, 0)
				end
				return v
			end
		elseif t.k == "op" and t.v == "(" then
			local inner = ternary()
			expect(")")
			return inner
		elseif t.k == "op" and t.v == "-" then
			local inner = primary()
			return function(env)
				return -inner(env)
			end
		elseif t.k == "op" and t.v == "+" then
			return primary()
		elseif t.k == "op" and t.v == "!" then
			local inner = primary()
			return function(env)
				return if inner(env) == 0 then 1 else 0
			end
		end
		error(`unexpected end of "{s}"`, 0)
	end
	local function power(): Fn
		local base = primary()
		local t = peek()
		if t.k == "op" and t.v == "^" then
			take()
			local ex = power()
			return function(env)
				return base(env) ^ ex(env)
			end
		end
		return base
	end
	local function binary(next_level: () -> Fn, ops: { [string]: (number, number) -> number }): () -> Fn
		return function(): Fn
			local left = next_level()
			while true do
				local t = peek()
				local f = if t.k == "op" then ops[t.v] else nil
				if not f then
					return left
				end
				take()
				local l, r, op = left, next_level(), f
				left = function(env)
					return op(l(env), r(env))
				end
			end
		end
	end
	local b = function(x: boolean): number
		return if x then 1 else 0
	end
	local term = binary(power, {
		["*"] = function(a, c) return a * c end,
		["/"] = function(a, c) return a / c end,
		["%"] = function(a, c) return a % c end,
	})
	local sum = binary(term, {
		["+"] = function(a, c) return a + c end,
		["-"] = function(a, c) return a - c end,
	})
	local compare = binary(sum, {
		["<"] = function(a, c) return b(a < c) end,
		[">"] = function(a, c) return b(a > c) end,
		["<="] = function(a, c) return b(a <= c) end,
		[">="] = function(a, c) return b(a >= c) end,
		["=="] = function(a, c) return b(math.abs(a - c) < 1e-9) end,
		["!="] = function(a, c) return b(math.abs(a - c) >= 1e-9) end,
	})
	local both = binary(compare, { ["&&"] = function(a, c) return b(a ~= 0 and c ~= 0) end })
	local either = binary(both, { ["||"] = function(a, c) return b(a ~= 0 or c ~= 0) end })
	ternary = function(): Fn
		local cond = either()
		local t = peek()
		if t.k == "op" and t.v == "?" then
			take()
			local yes = ternary()
			expect(":")
			local no = ternary()
			return function(env)
				return if cond(env) ~= 0 then yes(env) else no(env)
			end
		end
		return cond
	end
	local root = ternary()
	if peek().k ~= "end" then
		error(`unexpected "{tostring(peek().v)}" in "{s}"`, 0)
	end
	return root
end

local cache: { [string]: Fn } = {}
local cached = 0

-- A value of a design: a number, a boolean, or an expression string.
function M.eval(v: any, env: { [string]: number }): number
	local t = type(v)
	if t == "number" then
		return v
	elseif t == "boolean" then
		return if v then 1 else 0
	elseif t == "string" then
		local f = cache[v]
		if not f then
			f = parse(v)
			if cached > 2000 then
				cache = {}
				cached = 0
			end
			cache[v] = f
			cached += 1
		end
		local r = f(env)
		if r ~= r or r == math.huge or r == -math.huge then
			error(`"{v}" is not a finite number`, 0)
		end
		return r
	elseif v == nil then
		error("a number is missing", 0)
	end
	error(`expected a number, got {t}`, 0)
end

-- Checks an expression parses (for the inspector's fields).
function M.check(s: string): string?
	local ok, why = pcall(parse, s)
	return if ok then nil else tostring(why)
end

return M
