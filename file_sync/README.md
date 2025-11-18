SSL Sync Addon
Test

Этот аддон синхронизирует SSL сертификаты Nginx Proxy Manager с Asterisk, полностью в рамках одного устройства HAOS.

Настройки
source_relative_path: относительный путь к сертификатам NPM (от /addon_configs)
dest_relative_path: относительный путь назначения (от /ssl)
Запуск
Установите аддон.
Настройте source_relative_path и dest_relative_path.
Запустите аддон.
Сертификаты скопируются и аддон Asterisk будет перезапущен.
