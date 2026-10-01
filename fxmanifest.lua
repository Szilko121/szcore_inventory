fx_version 'cerulean'
game 'gta5'
author 'SzCode / SzCore'
version '1.4.0-rc1'
shared_script '@szcore/shared/items.lua'
ui_page 'web/index.html'
files {'web/index.html','web/style.css','web/app.js'}
server_scripts {'@oxmysql/lib/MySQL.lua','server/main.lua'}
client_script 'client/main.lua'
dependencies {'oxmysql','szcore'}
