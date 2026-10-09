-- the alliance's second party; see components/alliance.lua.
package.loaded['components.alliance'] = nil; -- so `/cc alliance1 reload` picks up edits to it too
return require('components.alliance').new(1);
