# wserv — Minimal HTTP File Server for RouterOS

---

## 🇷🇺 Русская версия

### Описание

**wserv** — небольшой HTTP-сервер для Windows, предназначенный для приёма и передачи файлов в **доверенной локальной сети**, в первую очередь для интеграции с **RouterOS 7.x** (MikroTik).

Программа ориентирована на простоту, предсказуемое поведение и отсутствие внешних зависимостей.  
Сервер не предназначен для использования в интернете.

---

### Возможности

- HTTP-сервер (IPv4)
- Поддерживаемые методы:
  - `GET`, `HEAD` — скачивание файлов
  - `POST` — загрузка файлов
- Работа со статическими файлами из каталога `www`
- Два способа загрузки файлов:
  - multipart/form-data
  - raw POST body
- Опциональная защита загрузок token’ом
- Ограничение размера запроса: **16 MB**
- Очистка зависших соединений
- Опциональное логирование запросов

---

### Ключи командной строки

```text
wserv.exe [/p:PORT] [/t:TOKEN] [/l] [/h]
````

#### `/p:<port>`

Задаёт TCP-порт сервера.
По умолчанию: `8080`

#### `/t:<token>`

Задаёт token для защиты загрузок (`POST`).

* Token применяется **только к POST**
* Передаётся через query-string (`?token=SECRET`)
* Считывается **один раз при старте сервера**
* Пустой token отключает авторизацию загрузок

#### `/l`

Включает логирование запросов в файл `wserv.log`.

#### `/h` или `/?`

Показывает справку и завершает работу.

---

### Endpoints

#### Проверка работоспособности

```
GET  /
GET  /status
HEAD /
HEAD /status
```

`/status` возвращает:

```
http server status: ok
```

---

#### Скачивание файлов

```
GET  /<filename>
GET  /www/<filename>
HEAD /<filename>
```

* Файлы берутся из каталога `www`
* Директории в URL игнорируются
* `GET` и `HEAD` всегда публичные

---

#### Загрузка файлов (multipart)

```
POST /upload?token=<token>
```

* Ожидается `multipart/form-data`
* Файл сохраняется в каталог `www`
* HTML-форма загрузки отсутствует

---

#### Загрузка файлов (raw)

```
POST /upload-raw?name=<filename>&token=<token>
```

* Всё тело POST сохраняется как файл
* Имя файла задаётся параметром `name`
* Предназначено для RouterOS `/tool fetch`

---

### Модель безопасности

⚠ **Важно**

* Сервер предназначен **только для доверенной локальной сети**
* ❌ Нет HTTPS / TLS
* ❌ Нет шифрования
* ❌ Нет сложной аутентификации
* `GET` и `HEAD` всегда без token’а
* Логи доступны только администратору

---

### Ограничения

* Только IPv4
* Только HTTP/1.1
* `Connection: close`
* Нет chunked transfer encoding
* Требуется `Content-Length`
* Файлы **перезаписываются без предупреждения**
* Зависшие соединения удаляются через ~30 секунд

---

### Файловая система

Все файлы хранятся в каталоге `www` рядом с `wserv.exe`.

---

### Ограничения на имена файлов

Разрешены символы:

```
A–Z  a–z  0–9  _  .  -
```

Запрещены:

* `/` `\`
* `..`
* пробелы
* спецсимволы

---

### Назначение

Подходит для:

* backup / restore RouterOS
* передачи конфигураций и скриптов
* lab / test-сред

Не подходит для:

* публичных серверов
* интернет-доступа
* многопользовательских сред

---

## 🇬🇧 English Version

### Description

**wserv** is a small HTTP server for Windows designed to send and receive files inside a **trusted local network**, primarily for **RouterOS 7.x** (MikroTik) integration.

The server focuses on simplicity, predictability, and zero external dependencies.
It is **not intended for internet-facing use**.

---

### Features

* IPv4 HTTP server
* Supported methods:

  * `GET`, `HEAD` — file download
  * `POST` — file upload
* Static file serving from `www` directory
* Two upload modes:

  * multipart/form-data
  * raw POST body
* Optional upload protection via token
* Request size limit: **16 MB**
* Automatic cleanup of stalled connections
* Optional request logging

---

### Command Line Arguments

```text
wserv.exe [/p:PORT] [/t:TOKEN] [/l] [/h]
```

#### `/p:<port>`

Sets the TCP listening port.
Default: `8080`

#### `/t:<token>`

Sets an upload authorization token (`POST` only).

* Applies only to `POST`
* Passed via query string (`?token=SECRET`)
* Read once at server startup
* Empty token disables upload authentication

#### `/l`

Enables request logging to `wserv.log`.

#### `/h` or `/?`

Displays help and exits.

---

### Endpoints

#### Health check

```
GET  /
GET  /status
HEAD /
HEAD /status
```

---

#### File download

```
GET  /<filename>
GET  /www/<filename>
HEAD /<filename>
```

Files are served from the `www` directory.
`GET` and `HEAD` are always public.

---

#### Multipart upload

```
POST /upload?token=<token>
```

Accepts `multipart/form-data`.
No HTML upload form is provided.

---

#### Raw upload

```
POST /upload-raw?name=<filename>&token=<token>
```

Saves the raw POST body as a file.
Designed for RouterOS `/tool fetch`.

---

### Security model

⚠ **Important**

* Designed for trusted LAN only
* ❌ No HTTPS / TLS
* ❌ No encryption
* ❌ No advanced authentication
* `GET` and `HEAD` do not require a token
* Logs are accessible only to the administrator

---

### Limitations

* IPv4 only
* HTTP/1.1 only
* `Connection: close`
* No chunked transfer encoding
* `Content-Length` required
* Files overwrite without warning
* Stalled connections are removed after ~30 seconds

---

### File system

All files are stored in the `www` directory next to `wserv.exe`.

---

### Filename restrictions

Allowed characters:

```
A–Z  a–z  0–9  _  .  -
```

Forbidden:

* `/` `\`
* `..`
* spaces
* special characters

---

### Intended use

Suitable for:

* RouterOS backup / restore
* configuration and script transfer
* lab / test environments

Not suitable for:

* public servers
* internet exposure
* multi-user environments

---

## License

Use at your own risk.
Designed for controlled local environments.

