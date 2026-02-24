---

# wserv - Minimal HTTP File Server for RouterOS

Lightweight single-purpose HTTP file server for use in a trusted local network
Минималистичный HTTP-сервер для работы в доверенной локальной сети

---

## 🇷🇺 Описание

**wserv** - небольшой HTTP-сервер для Windows, предназначенный для приёма и выдачи файлов в **локальной сети**, в первую очередь для интеграции с **RouterOS 7.x**.

Проект ориентирован на:

* простоту,
* предсказуемое поведение,
* отсутствие зависимостей,
* работу в доверенной LAN-среде.

Программа поставляется одним `.exe` файлом, имеет минимальный GUI и может работать скрыто.

---

## Возможности

* HTTP-сервер (IPv4)
* Поддерживаемые методы:

  * `GET`, `HEAD` - получение файлов
  * `POST` - загрузка файлов
* Статические файлы из папки `www`
* Два режима загрузки файлов:

  * multipart/form-data
  * raw POST body
* Опциональная защита загрузок token’ом
* Ограничение размера запроса (16 MB)
* Очистка зависших соединений
* Простое логирование (по желанию)

---

## Endpoints

### Проверка работоспособности

```
GET  /
GET  /status
HEAD /
HEAD /status
```

`/status` возвращает текст:

```
http server status: ok
```

Token не требуется.

---

### Скачивание файлов

```
GET  /<filename>
GET  /www/<filename>
HEAD /<filename>
```

* Файлы берутся из папки `www`
* Директория в URL игнорируется:

  ```
  /backup.rsc
  /www/backup.rsc
  ```

  → оба отдают `www/backup.rsc`
* `HEAD` возвращает только заголовки
* Token не требуется

---

### Загрузка файлов (multipart)

```
POST /upload?token=<token>
```

* Ожидается `multipart/form-data`
* Файл сохраняется в `www/` под исходным именем
* HTML-формы сервер **не предоставляет**
* Предназначено для `curl`, скриптов и т.п.

**Пример (curl):**

```bash
curl -F "file=@backup.rsc" \
     "http://192.168.1.10:8080/upload?token=secret"
```

---

### Загрузка файлов (raw)

```
POST /upload-raw?name=<filename>&token=<token>
```

* Тело POST сохраняется как файл
* Имя файла берётся из `name=`
* Предназначено для RouterOS `/tool fetch`

**Пример (RouterOS):**

```routeros
:local content [/file get backup.rsc contents]
/tool fetch \
  url="http://192.168.1.10:8080/upload-raw?name=backup.rsc&token=secret" \
  http-method=post \
  http-data=$content
```

---

## Авторизация

* Token применяется **только к POST**
* Token передаётся через query-string:

  ```
  ?token=SECRET
  ```
* Token считывается **один раз при старте сервера**
* `GET` и `HEAD` всегда публичные
* Пустой token = загрузки без авторизации

---

## Модель безопасности

⚠ **Важно**

* Сервер предназначен **только для доверенной локальной сети**
* ❌ Нет HTTPS / TLS
* ❌ Нет шифрования
* ❌ Нет сложной аутентификации
* ✅ Логи доступны только администратору

Рекомендуется:

* ограничивать доступ firewall’ом,
* не публиковать URL с token’ом,
* не использовать в публичных сетях.

---

## Ограничения

* Только IPv4
* Только HTTP/1.1
* `Connection: close`
* Нет chunked transfer encoding
* Требуется `Content-Length`
* Максимальный размер запроса: **16 MB**
* Файлы **перезаписываются без предупреждения**
* Зависшие клиенты удаляются через ~30 секунд

---

## Файловая система

Все файлы хранятся в папке `www` рядом с exe:

```
wserv.exe
www\
  backup.rsc
  config.txt
```

---

## Ограничения на имена файлов

Разрешены только:

```
A–Z  a–z  0–9  _  .  -
```

Запрещены:

* `/` `\`
* `..`
* пробелы
* спецсимволы

---

## Поддерживаемые MIME-типы

* `.txt .log .csv .rsc` → `text/plain`
* `.html .htm` → `text/html`
* `.css` → `text/css`
* `.js` → `application/javascript`
* `.json` → `application/json`
* `.png` → `image/png`
* `.jpg .jpeg` → `image/jpeg`
* `.gif` → `image/gif`
* `.pdf` → `application/pdf`
* прочее → `application/octet-stream`

---

## Для чего подходит

* Backup / restore RouterOS
* Передача конфигураций и скриптов
* Lab / test-среды
* Внутренние admin-утилиты

## Для чего НЕ подходит

* Публичные серверы
* Интернет-доступ
* Многопользовательская работа
* Среды с требованиями к безопасности

---

---

## 🇬🇧 Description

**wserv** is a small HTTP file server for Windows designed to operate **inside a trusted local network**, primarily for **RouterOS 7.x** integration.

It focuses on simplicity, predictability, and minimal dependencies.

---

## Features

* IPv4 HTTP server
* Supported methods: `GET`, `HEAD`, `POST`
* Static file serving from `www` directory
* Two upload modes:

  * multipart/form-data
  * raw POST body
* Optional token protection for uploads
* 16 MB request size limit
* Automatic cleanup of stalled connections
* Optional request logging

---

## Endpoints

### Health check

```
GET  /
GET  /status
HEAD /
HEAD /status
```

---

### File download

```
GET  /<filename>
GET  /www/<filename>
HEAD /<filename>
```

Files are served from the `www` directory.
`GET` and `HEAD` are always public.

---

### Multipart upload

```
POST /upload?token=<token>
```

Accepts `multipart/form-data`.
No HTML upload form is provided.

---

### Raw upload

```
POST /upload-raw?name=<filename>&token=<token>
```

Saves the raw POST body as a file.
Designed for RouterOS `/tool fetch`.

---

## Security model

* Designed for trusted LAN only
* No HTTPS / TLS
* No encryption
* Uploads protected by optional token
* GET/HEAD are public

---

## Limitations

* IPv4 only
* HTTP/1.1 only
* No chunked encoding
* `Content-Length` required
* Files overwrite without warning
* 16 MB max request size

---

## License

Use at your own risk.
Intended for controlled local environments.
