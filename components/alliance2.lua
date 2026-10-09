-- the alliance's third party; see components/alliance.lua.
package.loaded['components.alliance'] = nil; -- so `/cc alliance2 reload` picks up edits to it too
return require('components.alliance').new(2);
