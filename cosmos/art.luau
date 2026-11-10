-- Cosmos' drawings, as SVG markup: a sparkle and a shooting star's streak.
-- Original artwork. (The rocket is a model: ship.luau.)

local M = {}

-- A four-pointed star, to be tinted.
M.SPARKLE = [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 0C12.5 7.6 16.4 11.5 24 12 16.4 12.5 12.5 16.4 12 24 11.5 16.4 7.6 12.5 0 12 7.6 11.5 11.5 7.6 12 0Z"/></svg>]]

-- A shooting star's streak: bright at its head (the right), fading behind.
M.STREAK = [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 6"><defs><linearGradient id="g" x1="0" x2="1" y1="0" y2="0"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset="0.7" stop-color="#cfe0ff" stop-opacity="0.55"/><stop offset="1" stop-color="#fff"/></linearGradient></defs><path d="M0 3 L112 1.4 A1.9 1.9 0 0 1 112 4.6 Z" fill="url(#g)"/><circle cx="114" cy="3" r="2.6" fill="#fff"/></svg>]]

return M
