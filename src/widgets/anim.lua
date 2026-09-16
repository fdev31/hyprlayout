local ANIM_SPEED = 8

local AnimFloat = {}
AnimFloat.__index = AnimFloat

function AnimFloat.new(initial)
	return setmetatable({
		value = initial,
		target = initial,
		speed = ANIM_SPEED,
	}, AnimFloat)
end

function AnimFloat:advance()
	local v = self.value
	local t = self.target
	v = (v * self.speed + t) / (self.speed + 1)
	if math.abs(v - t) < 0.001 then
		v = t
	end
	self.value = v
	return v ~= t
end

function AnimFloat:snap(val)
	self.value = val
	self.target = val
end

local AnimColor = {}
AnimColor.__index = AnimColor

function AnimColor.new(r, g, b)
	return setmetatable({
		r = r,
		g = g,
		b = b,
		tr = r,
		tg = g,
		tb = b,
		speed = ANIM_SPEED,
	}, AnimColor)
end

function AnimColor:advance()
	local s = self.speed
	local function step(cur, tgt)
		local v = (cur * s + tgt) / (s + 1)
		if math.abs(v - tgt) < 0.01 then
			v = tgt
		end
		return v
	end
	self.r = step(self.r, self.tr)
	self.g = step(self.g, self.tg)
	self.b = step(self.b, self.tb)
	return self.r ~= self.tr or self.g ~= self.tg or self.b ~= self.tb
end

return {
	AnimFloat = AnimFloat,
	AnimColor = AnimColor,
}
