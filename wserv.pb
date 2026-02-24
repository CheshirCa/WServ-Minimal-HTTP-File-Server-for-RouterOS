; wserv.pb — Minimal HTTP file server
; Built with PureBasic 6.30 (Windows x86)
; Compile with: EnableXP linker flag

EnableExplicit

; ---------------------------------------------------------------
; Global settings — these values are used throughout the program
; ---------------------------------------------------------------

; Default port and bind address. Both can be changed from the GUI
; or via command line before starting the server.
Global ServerPort.i = 8080
Global BindIP.s     = "0.0.0.0"

; Upload token — if non-empty, every POST request must include
; ?token=<value> in the URL, otherwise the server replies 403.
; Empty string means no auth required.
Global UploadToken.s = ""

; Maximum request size: reject anything larger than 16 MB.
; Read chunk: how many bytes we pull from the socket at a time.
#MAX_REQUEST = 1024 * 1024 * 16
#READ_CHUNK  = 8192

; Files are stored in a "www" subfolder next to the exe.
; GetPathPart(ProgramFilename()) always returns the folder containing the exe,
; regardless of the working directory — safe for schedulers and services.
Global BaseDir.s = GetPathPart(ProgramFilename()) + "www" + #PS$
If FileSize(BaseDir) <> -2
  CreateDirectory(BaseDir)
EndIf

; ---------------------------------------------------------------
; Logging globals
; ---------------------------------------------------------------

; LogEnabled is set to #True when /l is passed on the command line.
Global LogEnabled.i = #False
Global LogFile.i    = 0       ; file handle returned by OpenFile / CreateFile
Global LogPath.s    = ""      ; full path to the log file
Global CmdLine.s    = ""      ; raw command line stored for the log header

; ---------------------------------------------------------------
; GUI widget IDs — PureBasic uses integer constants to identify
; windows and gadgets. Enumeration assigns unique numbers automatically.
; ---------------------------------------------------------------

Enumeration
  #WinMain
  #BtnStart
  #BtnStop
  #BtnClose
  #LblStatus
  #LblUrl
  #LblTokenLabel
  #EdtToken
  #LblIpLabel
  #CmbIP
  #LblPortLabel
  #EdtPort
  #BtnHelp
  #ChkLog        ; checkbox "Log"
  #EdtLogPath    ; editable path to the log file
  #BtnLogBrowse  ; "Browse..." button to pick log file location
EndEnumeration

; Server state: ID returned by CreateNetworkServer and a running flag.
Global ServerID.i      = 0
Global ServerRunning.i = #False

; ---------------------------------------------------------------
; Per-client receive buffer.
; Each connected client gets its own buffer where we accumulate
; incoming bytes until the full HTTP request has arrived.
; ---------------------------------------------------------------

Structure ClientBuf
  *mem              ; pointer to the allocated memory block
  size.i            ; bytes received so far
  cap.i             ; total allocated size of the block (capacity)
  lastActivity.i    ; Unix timestamp of the last data event, used to evict stuck clients
EndStructure

; One ClientBuf per client, keyed by the socket number as a string.
Global NewMap ClientBuffers.ClientBuf()

; Cache each client IP the moment they connect so we can log it
; even after the socket has been closed.
Global NewMap ClientIPs.s()


; ---------------------------------------------------------------
; String / filename helpers
; ---------------------------------------------------------------

; Replace special HTML characters with safe entities.
; This prevents XSS if we put user-supplied strings into HTML responses.
Procedure.s HtmlEscape(s.s)
  s = ReplaceString(s, "&",     "&amp;")
  s = ReplaceString(s, "<",     "&lt;")
  s = ReplaceString(s, ">",     "&gt;")
  s = ReplaceString(s, Chr(34), "&quot;")
  s = ReplaceString(s, "'",     "&#39;")
  ProcedureReturn s
EndProcedure

; Validate a filename before we write it to disk.
; Only letters, digits, dash, underscore and dot are allowed.
; Slashes and ".." are blocked to prevent directory traversal attacks.
Procedure.s SafeFileName(name.s)
  Protected i, c
  name = Trim(name)
  If name = "" : ProcedureReturn "" : EndIf
  If FindString(name, "/") Or FindString(name, "\") Or FindString(name, "..")
    ProcedureReturn ""
  EndIf
  For i = 1 To Len(name)
    c = Asc(Mid(name, i, 1))
    If (c >= '0' And c <= '9') Or
       (c >= 'A' And c <= 'Z') Or
       (c >= 'a' And c <= 'z') Or
       c = '_' Or c = '.' Or c = '-'
      ; character is allowed, keep going
    Else
      ProcedureReturn ""  ; illegal character — reject the whole name
    EndIf
  Next
  ProcedureReturn name
EndProcedure

; Decode percent-encoded URL strings: %20 becomes a space, + becomes a space, etc.
Procedure.s UrlDecode(s.s)
  Protected out.s, i.i, ch.s, hx.s, v.i
  i = 1
  While i <= Len(s)
    ch = Mid(s, i, 1)
    If ch = "+"
      out + " "                      ; "+" encodes a space in form data
    ElseIf ch = "%" And i + 2 <= Len(s)
      hx = Mid(s, i + 1, 2)         ; read two hex digits after the %
      v  = Val("$" + hx)            ; PureBasic treats "$XX" as hexadecimal
      out + Chr(v)
      i + 2                          ; skip the two hex digits we already consumed
    Else
      out + ch
    EndIf
    i + 1
  Wend
  ProcedureReturn out
EndProcedure

; Parse one named parameter from a URL query string.
; Example: query="name=backup.rsc&token=abc", paramName="token" => "abc"
; We split by "&" first, then by "=", so a name like "mytoken" never
; accidentally matches a search for "token".
Procedure.s GetQueryParam(query.s, paramName.s)
  Protected i.i, part.s, k.s, v.s, eq.i
  For i = 1 To CountString(query, "&") + 1
    part = StringField(query, i, "&")  ; get the i-th key=value pair
    eq   = FindString(part, "=", 1)    ; find the equals sign
    If eq
      k = Left(part, eq - 1)           ; everything before "=" is the key
      v = Mid(part, eq + 1)            ; everything after "=" is the value
    Else
      k = part : v = ""               ; no "=" means the param has no value
    EndIf
    If LCase(k) = LCase(paramName)
      ProcedureReturn UrlDecode(v)     ; found it — decode percent-encoding and return
    EndIf
  Next
  ProcedureReturn ""                   ; parameter not found
EndProcedure

; ---------------------------------------------------------------
; Logging
; ---------------------------------------------------------------

; Return the IP address of a connected client as a dotted-decimal string.
; GetClientIP() is PureBasic's built-in function that calls the OS network
; stack directly. IPString() converts the returned integer/handle to text.
; For IPv6 connections FreeIP() must be called on the raw value, but since
; this server binds IPv4 only we always get a plain IPv4 integer back.
Procedure.s SocketToIP(Client)
  Protected ip.i, ipStr.s
  ip    = GetClientIP(Client)      ; built-in: returns IPv4 as integer
  ipStr = IPString(ip)             ; built-in: converts to "a.b.c.d" string
  If ipStr = "" : ProcedureReturn "?.?.?.?" : EndIf
  ProcedureReturn ipStr
EndProcedure

; Return the cached IP for a client, or ask the OS if the cache misses.
Procedure.s ClientIPStr(Client)
  Protected key.s = Str(Client)
  If FindMapElement(ClientIPs(), key)
    ProcedureReturn ClientIPs(key)
  EndIf
  ProcedureReturn SocketToIP(Client)
EndProcedure

; Write one timestamped line to the log file.
; We flush after every write so the file stays readable even if the program crashes.
Procedure LogWrite(msg.s)
  Protected dt.s, line.s
  If Not LogEnabled Or LogFile = 0 : ProcedureReturn : EndIf
  dt   = FormatDate("%yyyy-%mm-%dd %hh:%ii:%ss", Date())
  line = dt + "  " + msg
  WriteStringN(LogFile, line, #PB_Ascii)
  FlushFileBuffers(LogFile)
EndProcedure

; Write a session header block to the log when the server starts.
; This makes it easy to find session boundaries when reading the log.
Procedure LogHeader()
  If Not LogEnabled Or LogFile = 0 : ProcedureReturn : EndIf
  WriteStringN(LogFile, "========================================", #PB_Ascii)
  WriteStringN(LogFile, "Server started: " + FormatDate("%yyyy-%mm-%dd %hh:%ii:%ss", Date()), #PB_Ascii)
  WriteStringN(LogFile, "Bind:           " + BindIP + ":" + Str(ServerPort), #PB_Ascii)
  WriteStringN(LogFile, "Token:          " + UploadToken, #PB_Ascii)
  WriteStringN(LogFile, "Command line:   " + CmdLine, #PB_Ascii)
  WriteStringN(LogFile, "========================================", #PB_Ascii)
  FlushFileBuffers(LogFile)
EndProcedure

; ---------------------------------------------------------------
; HTTP response helpers
; ---------------------------------------------------------------

; Forward declaration so SendFile can call SendText even though
; SendText is defined further down in this file.
Declare SendText(Client, statusCode.i, statusText.s, body.s, contentType.s = "text/html; charset=utf-8")

; Return the correct MIME type string for a given file extension.
; Falls back to a generic binary type for unknown extensions.
Procedure.s GuessMimeType(fileName.s)
  Protected ext.s = LCase(GetExtensionPart(fileName))
  Select ext
    Case "html", "htm"               : ProcedureReturn "text/html; charset=utf-8"
    Case "txt", "log", "csv", "rsc"  : ProcedureReturn "text/plain; charset=utf-8"
    Case "css"                       : ProcedureReturn "text/css; charset=utf-8"
    Case "js"                        : ProcedureReturn "application/javascript"
    Case "json"                      : ProcedureReturn "application/json"
    Case "png"                       : ProcedureReturn "image/png"
    Case "jpg", "jpeg"               : ProcedureReturn "image/jpeg"
    Case "gif"                       : ProcedureReturn "image/gif"
    Case "pdf"                       : ProcedureReturn "application/pdf"
    Default                          : ProcedureReturn "application/octet-stream"
  EndSelect
EndProcedure

; Send a file from disk to the client in 8 KB chunks.
; If the file does not exist we reply 404. Connection is closed when done.
Procedure SendFile(Client, fullPath.s, fileName.s)
  Protected fileSize.q, header.s, f, *buf, readBytes.i
  fileSize = FileSize(fullPath)
  If fileSize < 0
    SendText(Client, 404, "Not Found", "not found", "text/plain; charset=utf-8")
    ProcedureReturn
  EndIf
  ; Build the response header. Content-Length tells the client exactly
  ; how many bytes follow so it knows when the transfer is complete.
  header = "HTTP/1.1 200 OK" + #CRLF$
  header + "Server: PB-MinServer/1.1" + #CRLF$
  header + "Connection: close" + #CRLF$
  header + "Content-Type: " + GuessMimeType(fileName) + #CRLF$
  header + "Content-Length: " + Str(fileSize) + #CRLF$
  header + #CRLF$
  SendNetworkString(Client, header, #PB_Ascii)
  f = ReadFile(#PB_Any, fullPath)
  If f = 0 : ProcedureReturn : EndIf
  *buf = AllocateMemory(#READ_CHUNK)
  If *buf = 0 : CloseFile(f) : ProcedureReturn : EndIf
  ; Read the file in chunks and push each chunk over the network.
  While Eof(f) = 0
    readBytes = ReadData(f, *buf, #READ_CHUNK)
    If readBytes > 0 : SendNetworkData(Client, *buf, readBytes) : Else : Break : EndIf
  Wend
  FreeMemory(*buf)
  CloseFile(f)
  CloseNetworkConnection(Client)  ; signal to the client that we are done
EndProcedure

; Send headers-only response for HEAD requests on existing files.
; Reports the real Content-Length so the client knows the file size
; without having to download the body.
Procedure SendHeadFile(Client, fullPath.s, fileName.s)
  Protected fileSize.q, header.s
  fileSize = FileSize(fullPath)
  If fileSize < 0
    SendText(Client, 404, "Not Found", "not found", "text/plain; charset=utf-8")
    ProcedureReturn
  EndIf
  header = "HTTP/1.1 200 OK" + #CRLF$
  header + "Server: PB-MinServer/1.1" + #CRLF$
  header + "Connection: close" + #CRLF$
  header + "Content-Type: " + GuessMimeType(fileName) + #CRLF$
  header + "Content-Length: " + Str(fileSize) + #CRLF$  ; real file size, no body sent
  header + #CRLF$
  SendNetworkString(Client, header, #PB_Ascii)
  CloseNetworkConnection(Client)
EndProcedure

; Send a short text or HTML response and close the connection.
; statusCode is the HTTP status number: 200, 400, 403, 404, 500, etc.
Procedure SendText(Client, statusCode.i, statusText.s, body.s, contentType.s = "text/html; charset=utf-8")
  Protected header.s
  header = "HTTP/1.1 " + Str(statusCode) + " " + statusText + #CRLF$
  header + "Server: PB-MinServer/1.1" + #CRLF$
  header + "Connection: close" + #CRLF$
  header + "Content-Type: " + contentType + #CRLF$
  header + "Content-Length: " + Str(StringByteLength(body, #PB_UTF8)) + #CRLF$
  header + #CRLF$
  SendNetworkString(Client, header, #PB_Ascii)  ; HTTP headers must be ASCII
  SendNetworkString(Client, body,   #PB_UTF8)   ; body may contain UTF-8 text
  CloseNetworkConnection(Client)
EndProcedure

; ---------------------------------------------------------------
; Binary memory search utilities (needed for multipart parsing)
; ---------------------------------------------------------------

; Search for byte pattern *pat inside buffer *buf starting at startPos.
; Returns the offset of the first match, or -1 if not found.
; Simple brute-force scan — fast enough for typical HTTP bodies.
Procedure.i FindMem(*buf, bufLen.i, *pat, patLen.i, startPos.i = 0)
  Protected i.i, j.i
  If patLen <= 0 Or bufLen <= 0 Or startPos < 0 : ProcedureReturn -1 : EndIf
  If startPos + patLen > bufLen : ProcedureReturn -1 : EndIf
  For i = startPos To bufLen - patLen
    For j = 0 To patLen - 1
      If PeekA(*buf + i + j) <> PeekA(*pat + j) : Break : EndIf
    Next
    If j = patLen : ProcedureReturn i : EndIf  ; all bytes matched
  Next
  ProcedureReturn -1
EndProcedure

; Extract the value of one HTTP header from the header block string.
; Example: GetHeaderValue(headers, "Content-Type") => "multipart/form-data; boundary=xxx"
Procedure.s GetHeaderValue(headers.s, headerName.s)
  Protected pos.i, lineEnd.i
  pos = FindString(headers, headerName + ":", 1, #PB_String_NoCase)
  If pos = 0 : ProcedureReturn "" : EndIf
  lineEnd = FindString(headers, #CRLF$, pos)
  If lineEnd = 0 : lineEnd = Len(headers) + 1 : EndIf
  ProcedureReturn Trim(Mid(headers, pos + Len(headerName) + 1, lineEnd - (pos + Len(headerName) + 1)))
EndProcedure

; Find the opening boundary marker of a multipart body.
; The marker must be at the start of a line and followed by CRLF or LF.
; On success, sets *partStart to the offset where the first part's headers begin
; and returns the offset of the boundary line itself.
Procedure.i FindStartBoundaryRaw(*buf, bufLen.i, *markerRaw, markerLen.i, *partStart.Integer)
  Protected p.i = 0, preOk.i, postLen.i
  If markerLen <= 0 Or bufLen <= markerLen : ProcedureReturn -1 : EndIf
  While #True
    p = FindMem(*buf, bufLen, *markerRaw, markerLen, p)
    If p < 0 : ProcedureReturn -1 : EndIf
    ; The byte before the marker must be a newline, or we must be at position 0.
    preOk = #False
    If p = 0 : preOk = #True
    ElseIf PeekA(*buf + p - 1) = 10 : preOk = #True
    ElseIf p >= 2 And PeekA(*buf + p - 2) = 13 And PeekA(*buf + p - 1) = 10 : preOk = #True
    EndIf
    If preOk
      ; The bytes right after the marker must be CRLF or LF.
      postLen = 0
      If p + markerLen + 1 < bufLen And PeekA(*buf + p + markerLen) = 13 And PeekA(*buf + p + markerLen + 1) = 10
        postLen = 2  ; CRLF
      ElseIf p + markerLen < bufLen And PeekA(*buf + p + markerLen) = 10
        postLen = 1  ; LF only
      EndIf
      If postLen > 0
        *partStart\i = p + markerLen + postLen  ; the first part's headers start here
        ProcedureReturn p
      EndIf
    EndIf
    p + 1  ; no match at this position, try one byte further
  Wend
EndProcedure

; Extract a named parameter value from a Content-Disposition header.
; Example: GetDispParam("form-data; name=\"file\"; filename=\"test.txt\"", "filename") => "test.txt"
Procedure.s GetDispParam(dispLine.s, paramName.s)
  Protected dq.s = Chr(34), p.i, s.s, q.i
  p = FindString(dispLine, paramName + "=", 1, #PB_String_NoCase)
  If p = 0 : ProcedureReturn "" : EndIf
  s = Trim(Mid(dispLine, p + Len(paramName) + 1))
  If Left(s, 1) = dq
    ; value is quoted — strip the leading quote and find the closing one
    s = Mid(s, 2)
    q = FindString(s, dq, 1)
    If q : s = Left(s, q - 1) : EndIf
    ProcedureReturn s
  Else
    ; unquoted value ends at the next semicolon
    q = FindString(s, ";", 1)
    If q : s = Left(s, q - 1) : EndIf
    ProcedureReturn Trim(s)
  EndIf
EndProcedure

; ---------------------------------------------------------------
; Multipart upload handler
; ---------------------------------------------------------------

; Parse a multipart/form-data body and save the first file part to disk.
; Returns #True if a file was saved successfully, #False otherwise.
; We operate on raw bytes so binary file content is never corrupted
; by string encoding conversions.
Procedure.i HandleUploadMultipart(Client, headers.s, *body, bodyLen.i)
  Protected ctype.s = GetHeaderValue(headers, "Content-Type")
  Protected dq.s = Chr(34)
  Protected bpos.i, boundary.s, markerS.s
  Protected delimCRLF.s, delimLF.s, hdrCRLFCRLF.s, hdrLFLF.s
  ; All pattern buffers start at 0 so Cleanup can safely check them with If.
  Protected *markerRaw = 0, *delimCRLF = 0, *delimLF = 0, *hdrCRLFCRLF = 0, *hdrLFLF = 0
  Protected markerRawLen.i, delimCRLFLen.i, delimLFLen.i, hdrCRLFCRLFLen.i, hdrLFLFLen.i
  Protected pos.i, partStart.i, headEnd.i, dataStart.i, nextBound.i, nextType.i, dataEnd.i
  Protected partHeaders.s, disp.s, nameField.s, fileName.s, safeName.s
  Protected savePath.s, f.i, foundFile.i = #False, p1.i, p2.i

  ; The Content-Type header contains the boundary string that separates parts.
  bpos = FindString(ctype, "boundary=", 1, #PB_String_NoCase)
  If bpos = 0 : SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Missing boundary.</p>") : ProcedureReturn 0 : EndIf
  boundary = Trim(Mid(ctype, bpos + Len("boundary=")))
  boundary = ReplaceString(boundary, dq, "")
  If boundary = "" : SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Empty boundary.</p>") : ProcedureReturn 0 : EndIf

  ; Build the raw byte patterns we will search for inside the body:
  ; markerS      = "--boundary"               (the boundary line itself)
  ; delimCRLF    = "\r\n--boundary"           (separator between parts, CRLF variant)
  ; delimLF      = "\n--boundary"             (separator, LF-only variant)
  ; hdrCRLFCRLF  = "\r\n\r\n"                (blank line ending the part headers, CRLF)
  ; hdrLFLF      = "\n\n"                    (same, LF-only)
  markerS        = "--" + boundary
  markerRawLen   = StringByteLength(markerS,     #PB_Ascii)
  delimCRLF      = #CRLF$ + markerS : delimCRLFLen   = StringByteLength(delimCRLF,   #PB_Ascii)
  delimLF        = Chr(10) + markerS : delimLFLen     = StringByteLength(delimLF,     #PB_Ascii)
  hdrCRLFCRLF    = #CRLF$ + #CRLF$  : hdrCRLFCRLFLen = StringByteLength(hdrCRLFCRLF, #PB_Ascii)
  hdrLFLF        = Chr(10) + Chr(10) : hdrLFLFLen     = StringByteLength(hdrLFLF,     #PB_Ascii)

  ; Allocate memory for each pattern and copy the ASCII bytes into it.
  *markerRaw   = AllocateMemory(markerRawLen   + 1)
  *delimCRLF   = AllocateMemory(delimCRLFLen   + 1)
  *delimLF     = AllocateMemory(delimLFLen     + 1)
  *hdrCRLFCRLF = AllocateMemory(hdrCRLFCRLFLen + 1)
  *hdrLFLF     = AllocateMemory(hdrLFLFLen     + 1)
  If *markerRaw = 0 Or *delimCRLF = 0 Or *delimLF = 0 Or *hdrCRLFCRLF = 0 Or *hdrLFLF = 0
    SendText(Client, 500, "Internal Server Error", "<h1>500</h1><p>Out of memory.</p>")
    Goto Cleanup
  EndIf
  PokeS(*markerRaw,   markerS,     -1, #PB_Ascii)
  PokeS(*delimCRLF,   delimCRLF,   -1, #PB_Ascii)
  PokeS(*delimLF,     delimLF,     -1, #PB_Ascii)
  PokeS(*hdrCRLFCRLF, hdrCRLFCRLF, -1, #PB_Ascii)
  PokeS(*hdrLFLF,     hdrLFLF,     -1, #PB_Ascii)

  ; Find the first boundary to locate where the first part begins.
  pos = FindStartBoundaryRaw(*body, bodyLen, *markerRaw, markerRawLen, @partStart)
  If pos < 0
    SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Malformed multipart (no start boundary).</p>")
    Goto Cleanup
  EndIf

  ; Iterate over parts until we find and save one that carries a filename.
  While partStart < bodyLen And foundFile = #False

    ; Find the blank line that separates this part's headers from its data.
    ; Try CRLF+CRLF first, then fall back to LF+LF.
    headEnd = FindMem(*body, bodyLen, *hdrCRLFCRLF, hdrCRLFCRLFLen, partStart)
    If headEnd >= 0
      partHeaders = PeekS(*body + partStart, headEnd - partStart, #PB_Ascii)
      dataStart   = headEnd + hdrCRLFCRLFLen
    Else
      headEnd = FindMem(*body, bodyLen, *hdrLFLF, hdrLFLFLen, partStart)
      If headEnd < 0
        SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Malformed multipart (no part headers end).</p>")
        Goto Cleanup
      EndIf
      partHeaders = PeekS(*body + partStart, headEnd - partStart, #PB_Ascii)
      dataStart   = headEnd + hdrLFLFLen
    EndIf

    ; Read the Content-Disposition header to find the field name and filename.
    disp      = GetHeaderValue(partHeaders, "Content-Disposition")
    nameField = GetDispParam(disp, "name")
    fileName  = GetDispParam(disp, "filename")

    ; Find the boundary that ends this part's data.
    ; We check both CRLF and LF variants and pick whichever comes first.
    nextBound = -1 : nextType = 0
    p1 = FindMem(*body, bodyLen, *delimCRLF, delimCRLFLen, dataStart)
    p2 = FindMem(*body, bodyLen, *delimLF,   delimLFLen,   dataStart)
    If p1 >= 0 And p2 >= 0
      If p1 <= p2 : nextBound = p1 : nextType = 1 : Else : nextBound = p2 : nextType = 2 : EndIf
    ElseIf p1 >= 0 : nextBound = p1 : nextType = 1
    ElseIf p2 >= 0 : nextBound = p2 : nextType = 2
    EndIf
    If nextBound < 0
      SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Malformed multipart (missing next boundary).</p>")
      Goto Cleanup
    EndIf
    dataEnd = nextBound  ; file data occupies bytes dataStart .. dataEnd-1

    ; Save the first part that has a filename, regardless of the field name.
    If fileName <> ""
      safeName = SafeFileName(fileName)
      If safeName = ""
        SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Invalid filename.</p>")
        Goto Cleanup
      EndIf
      savePath = BaseDir + safeName
      f = CreateFile(#PB_Any, savePath)
      If f = 0
        SendText(Client, 500, "Internal Server Error", "<h1>500</h1><p>Cannot save file.</p>")
        Goto Cleanup
      EndIf
      If dataEnd > dataStart : WriteData(f, *body + dataStart, dataEnd - dataStart) : EndIf
      CloseFile(f)
      foundFile = #True
    EndIf

    ; Skip past the boundary we just found to move to the next part.
    If nextType = 1 : pos = nextBound + 2 : Else : pos = nextBound + 1 : EndIf
    If pos + markerRawLen > bodyLen
      SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Malformed multipart (truncated boundary).</p>")
      Goto Cleanup
    EndIf
    pos + markerRawLen
    ; Two dashes after the boundary mean it is the final boundary — we are done.
    If pos + 1 < bodyLen And PeekA(*body + pos) = 45 And PeekA(*body + pos + 1) = 45 : Break : EndIf
    ; Otherwise move past the line ending to reach the next part's headers.
    If pos + 1 < bodyLen And PeekA(*body + pos) = 13 And PeekA(*body + pos + 1) = 10
      partStart = pos + 2
    ElseIf pos < bodyLen And PeekA(*body + pos) = 10
      partStart = pos + 1
    Else
      SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Malformed multipart (missing line break after boundary).</p>")
      Goto Cleanup
    EndIf
  Wend

  If foundFile
    SendText(Client, 200, "OK", "saved", "text/plain; charset=utf-8")
  Else
    SendText(Client, 400, "Bad Request", "<h1>400</h1><p>No file part found.</p>")
  EndIf

  ; Free all pattern buffers. We reach this label both normally and via Goto on error.
Cleanup:
  If *markerRaw   : FreeMemory(*markerRaw)   : EndIf
  If *delimCRLF   : FreeMemory(*delimCRLF)   : EndIf
  If *delimLF     : FreeMemory(*delimLF)     : EndIf
  If *hdrCRLFCRLF : FreeMemory(*hdrCRLFCRLF) : EndIf
  If *hdrLFLF     : FreeMemory(*hdrLFLF)     : EndIf
  ProcedureReturn foundFile
EndProcedure

; ---------------------------------------------------------------
; Main HTTP request processor
; ---------------------------------------------------------------

; Called once a complete request has been assembled in memory.
; *req points to the raw bytes of the entire request (headers + optional body).
Procedure ProcessRequest(Client, *req, reqLen.i)
  Protected reqStr.s, headerEnd.i, headers.s, bodyOffset.i, bodyLen.i
  Protected requestLine.s, method.s, rawPath.s, path.s, query.s
  Protected sp1.i, sp2.i, qpos.i
  Protected rawName.s, rawF.i, token.s, safe.s
  Protected clientIP.s = ClientIPStr(Client)  ; grab the IP once for logging

  If reqLen <= 0 : ProcedureReturn : EndIf

  ; Convert raw bytes to a string so we can use string search functions.
  ; HTTP headers are always ASCII, so the conversion is lossless.
  reqStr    = PeekS(*req, reqLen, #PB_Ascii)

  ; The blank line "\r\n\r\n" separates the headers from the body.
  headerEnd = FindString(reqStr, #CRLF$ + #CRLF$, 1)
  If headerEnd = 0
    SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Bad headers.</p>")
    ProcedureReturn
  EndIf

  ; Split the request into headers and body.
  headers    = Left(reqStr, headerEnd + 3)
  bodyOffset = (headerEnd - 1) + 4  ; byte index where the body starts
  bodyLen    = reqLen - bodyOffset

  ; Parse the request line: "GET /path HTTP/1.1"
  requestLine = StringField(headers, 1, #CRLF$)
  sp1 = FindString(requestLine, " ", 1)
  sp2 = FindString(requestLine, " ", sp1 + 1)
  If sp1 = 0 Or sp2 = 0
    SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Bad request line.</p>")
    ProcedureReturn
  EndIf
  method  = UCase(Left(requestLine, sp1 - 1))         ; "GET", "POST", "HEAD", ...
  rawPath = Mid(requestLine, sp1 + 1, sp2 - sp1 - 1)  ; "/upload?token=abc"

  ; Split rawPath into the path and the query string.
  qpos = FindString(rawPath, "?", 1)
  If qpos
    path  = Left(rawPath, qpos - 1)  ; "/upload"
    query = Mid(rawPath, qpos + 1)   ; "token=abc&name=file.rsc"
  Else
    path  = rawPath
    query = ""
  EndIf

  ; ---- Route: GET and HEAD ----
  If method = "GET" Or method = "HEAD"

    If path = "/" Or path = "/status"
      ; Simple health-check endpoint — returns "http server status: ok".
      ; HEAD returns the same headers but with no body (as per the HTTP spec).
      If method = "HEAD"
        SendText(Client, 200, "OK", "", "text/plain; charset=utf-8")
      Else
        SendText(Client, 200, "OK", "http server status: ok", "text/plain; charset=utf-8")
      EndIf
      LogWrite(clientIP + "  " + method + " " + rawPath + "  200 status")

    Else
      ; Try to serve a file from the www/ folder.
      ; GetFilePart strips any directory prefix from the URL so both
      ; "/backup.rsc" and "/www/backup.rsc" resolve to "backup.rsc".
      safe = SafeFileName(GetFilePart(path))
      If safe <> "" And FileSize(BaseDir + safe) >= 0
        LogWrite(clientIP + "  " + method + " " + rawPath + "  200 file " + safe)
        If method = "HEAD"
          ; HEAD: send real headers with correct Content-Length, no body
          SendHeadFile(Client, BaseDir + safe, safe)
        Else
          SendFile(Client, BaseDir + safe, safe)
        EndIf
      Else
        SendText(Client, 404, "Not Found", "not found", "text/plain; charset=utf-8")
        LogWrite(clientIP + "  " + method + " " + rawPath + "  404")
      EndIf
    EndIf

  ; ---- Route: POST ----
  ElseIf method = "POST"

    ; Check the upload token only when a server token is configured.
    ; If UploadToken is empty the server runs in open mode and any POST is allowed.
    token = GetQueryParam(query, "token")
    If UploadToken <> "" And token <> UploadToken
      SendText(Client, 403, "Forbidden", "<h1>403 Forbidden</h1><p>Invalid or missing token.</p>")
      LogWrite(clientIP + "  POST " + rawPath + "  403 bad token")
      ProcedureReturn
    EndIf

    If path = "/upload"
      ; Multipart upload from an HTML form.
      If bodyLen <= 0
        SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Empty body.</p>")
        LogWrite(clientIP + "  POST " + rawPath + "  400 empty body")
      Else
        If HandleUploadMultipart(Client, headers, *req + bodyOffset, bodyLen)
          LogWrite(clientIP + "  POST " + rawPath + "  200 multipart upload ok")
        Else
          LogWrite(clientIP + "  POST " + rawPath + "  400 multipart upload failed")
        EndIf
      EndIf

    ElseIf path = "/upload-raw"
      ; Raw POST upload for RouterOS and other simple HTTP clients.
      ; The target filename comes from ?name=, the body is the raw file content.
      rawName = SafeFileName(GetQueryParam(query, "name"))
      If rawName = ""
        SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Missing or invalid ?name= parameter.</p>")
        LogWrite(clientIP + "  POST " + rawPath + "  400 bad ?name=")
      ElseIf bodyLen <= 0
        SendText(Client, 400, "Bad Request", "<h1>400</h1><p>Empty body.</p>")
        LogWrite(clientIP + "  POST " + rawPath + "  400 empty body")
      Else
        rawF = CreateFile(#PB_Any, BaseDir + rawName)
        If rawF = 0
          SendText(Client, 500, "Internal Server Error", "<h1>500</h1><p>Cannot save file.</p>")
          LogWrite(clientIP + "  POST " + rawPath + "  500 cannot save " + rawName)
        Else
          WriteData(rawF, *req + bodyOffset, bodyLen)  ; write raw bytes, no encoding
          CloseFile(rawF)
          SendText(Client, 200, "OK", "<h1>Saved</h1><p>" + HtmlEscape(rawName) + " (" + Str(bodyLen) + " bytes)</p>")
          LogWrite(clientIP + "  POST " + rawPath + "  200 saved " + rawName + " (" + Str(bodyLen) + " bytes)")
        EndIf
      EndIf

    Else
      SendText(Client, 404, "Not Found", "<h1>404</h1><p>Not found.</p>")
      LogWrite(clientIP + "  POST " + rawPath + "  404")
    EndIf

  Else
    ; We do not support any other HTTP methods.
    SendText(Client, 405, "Method Not Allowed", "<h1>405</h1><p>Only GET/HEAD/POST supported.</p>")
    LogWrite(clientIP + "  " + method + " " + rawPath + "  405")
  EndIf
EndProcedure

; ---------------------------------------------------------------
; Buffer helper functions
; ---------------------------------------------------------------

; Scan *mem for the "\r\n\r\n" sequence that marks the end of HTTP headers.
; Returns the byte offset of the first body byte, or -1 if not found yet.
Procedure.i GetHeadersEnd(*mem, size.i)
  Protected headerEnd.i
  headerEnd = FindString(PeekS(*mem, size, #PB_Ascii), #CRLF$ + #CRLF$, 1)
  If headerEnd = 0 : ProcedureReturn -1 : EndIf
  ProcedureReturn (headerEnd - 1) + 4
EndProcedure

; Read the Content-Length header from the buffer and return its value.
; Returns -1 if the header is absent (RouterOS sometimes omits it).
; Returns 0 if the header exists but its value is 0.
Procedure.i GetContentLength(*mem, size.i)
  Protected str.s, headerEnd.i, headers.s, pos.i, lineEnd.i, cl.i
  str       = PeekS(*mem, size, #PB_Ascii)
  headerEnd = FindString(str, #CRLF$ + #CRLF$, 1)
  If headerEnd = 0 : ProcedureReturn -1 : EndIf
  headers = Left(str, headerEnd + 3)
  pos = FindString(headers, "Content-Length:", 1, #PB_String_NoCase)
  If pos = 0 : ProcedureReturn -1 : EndIf
  lineEnd = FindString(headers, #CRLF$, pos)
  If lineEnd = 0 : lineEnd = Len(headers) + 1 : EndIf
  cl = Val(Trim(Mid(headers, pos + Len("Content-Length:"), lineEnd - (pos + Len("Content-Length:")))))
  If cl < 0 : cl = 0 : EndIf
  ProcedureReturn cl
EndProcedure

; ---------------------------------------------------------------
; Network event handlers
; ---------------------------------------------------------------

; Called each time the OS signals that a client has sent data.
; We append the bytes to the client's buffer, then check if we have
; a complete HTTP request. Returns #True if the request was processed.
Procedure.i ClientAppendAndCheck(Client)
  Protected key.s = Str(Client)
  Protected *chunk, got.i, *newmem
  Protected bodyOffset.i, contentLen.i, needTotal.i
  Protected reqStr.s, reqMethod.s

  ; On the first data event for this client, allocate a fresh buffer.
  If Not FindMapElement(ClientBuffers(), key)
    AddMapElement(ClientBuffers(), key)
    ClientBuffers()\mem  = AllocateMemory(#READ_CHUNK)
    ClientBuffers()\cap  = #READ_CHUNK
    ClientBuffers()\size = 0
    If ClientBuffers()\mem = 0
      DeleteMapElement(ClientBuffers(), key)
      ProcedureReturn #False
    EndIf
  EndIf

  ; Temporary chunk to drain whatever the OS has buffered for this client.
  *chunk = AllocateMemory(#READ_CHUNK)
  If *chunk = 0 : ProcedureReturn #False : EndIf

  Repeat
    got = ReceiveNetworkData(Client, *chunk, #READ_CHUNK)
    If got <= 0 : Break : EndIf

    ; Refuse requests that exceed the maximum size.
    If ClientBuffers()\size + got > #MAX_REQUEST
      FreeMemory(*chunk)
      SendText(Client, 413, "Payload Too Large", "<h1>413</h1>")
      If ClientBuffers()\mem : FreeMemory(ClientBuffers()\mem) : EndIf
      DeleteMapElement(ClientBuffers(), key)
      ProcedureReturn #True
    EndIf

    ; Grow the buffer if the new data does not fit.
    ; We save the old pointer before calling ReAllocateMemory because if it
    ; returns 0 the old block is still valid and we must free it ourselves.
    If ClientBuffers()\size + got > ClientBuffers()\cap
      ClientBuffers()\cap = (ClientBuffers()\size + got) * 2
      *newmem = ReAllocateMemory(ClientBuffers()\mem, ClientBuffers()\cap)
      If *newmem = 0
        FreeMemory(ClientBuffers()\mem)  ; free the old block to avoid a leak
        ClientBuffers()\mem = 0
        DeleteMapElement(ClientBuffers(), key)
        FreeMemory(*chunk)
        ProcedureReturn #False
      EndIf
      ClientBuffers()\mem = *newmem
    EndIf

    ; Append the new bytes to the end of what we already have.
    CopyMemory(*chunk, ClientBuffers()\mem + ClientBuffers()\size, got)
    ClientBuffers()\size + got
  Until got < #READ_CHUNK  ; when ReceiveNetworkData returns less than the chunk size, the OS buffer is empty

  FreeMemory(*chunk)

  ; Record the timestamp so the stale-client check in the main loop can evict
  ; clients that never send a complete request and never disconnect.
  ClientBuffers()\lastActivity = Date()

  ; Check if we have received the complete HTTP headers yet.
  bodyOffset = GetHeadersEnd(ClientBuffers()\mem, ClientBuffers()\size)
  If bodyOffset < 0 : ProcedureReturn #False : EndIf  ; still waiting for more data

  contentLen = GetContentLength(ClientBuffers()\mem, ClientBuffers()\size)
  reqMethod  = UCase(StringField(PeekS(ClientBuffers()\mem, ClientBuffers()\size, #PB_Ascii), 1, " "))

  If contentLen > 0
    ; We know the expected body size. Wait until all of it has arrived.
    If ClientBuffers()\size >= bodyOffset + contentLen
      ProcessRequest(Client, ClientBuffers()\mem, ClientBuffers()\size)
      FreeMemory(ClientBuffers()\mem)
      DeleteMapElement(ClientBuffers(), key)
      ProcedureReturn #True
    EndIf
    ProcedureReturn #False  ; body not fully received yet

  ElseIf reqMethod = "GET" Or reqMethod = "HEAD"
    ; GET and HEAD have no body, so we can process right away.
    ProcessRequest(Client, ClientBuffers()\mem, ClientBuffers()\size)
    FreeMemory(ClientBuffers()\mem)
    DeleteMapElement(ClientBuffers(), key)
    ProcedureReturn #True

  Else
    ; POST without Content-Length (e.g. RouterOS /tool/fetch quirk).
    ; We wait for the client to close the connection, which fires ClientDisconnect.
    ProcedureReturn #False
  EndIf
EndProcedure

; Called when a client closes its TCP connection.
; For clients that sent data without a Content-Length header (RouterOS),
; we now have everything they sent, so we process the buffered request.
Procedure ClientDisconnect(Client)
  Protected key.s = Str(Client)
  If FindMapElement(ClientBuffers(), key)
    If ClientBuffers()\size > 0
      ProcessRequest(Client, ClientBuffers()\mem, ClientBuffers()\size)
    EndIf
    If ClientBuffers()\mem : FreeMemory(ClientBuffers()\mem) : EndIf
    DeleteMapElement(ClientBuffers(), key)
  EndIf
EndProcedure

; ---------------------------------------------------------------
; Server control procedures
; ---------------------------------------------------------------

; ---------------------------------------------------------------
; Help dialog
; ---------------------------------------------------------------

; Build and display the help text in a message box.
; Called both by the Help button in the GUI and when the program
; is launched with ?, /?, -help, or --help on the command line.
Procedure ShowHelp()
  Protected msg.s
  msg = "wserv — Minimal HTTP file server (PureBasic 6.30)" + #CRLF$
  msg + #CRLF$
  msg + "ENDPOINTS" + #CRLF$
  msg + "  GET  /  or  /status              health check" + #CRLF$
  msg + "  HEAD /  or  /status              same, no body" + #CRLF$
  msg + "  GET  /<filename>                 download file from www/ folder" + #CRLF$
  msg + "  HEAD /<filename>                 check file size without downloading" + #CRLF$
  msg + "  POST /upload?token=X             multipart upload (curl -F)" + #CRLF$
  msg + "  POST /upload-raw?name=F&token=X  raw body upload (RouterOS)" + #CRLF$
  msg + #CRLF$
  msg + "COMMAND LINE PARAMETERS" + #CRLF$
  msg + "  /a:<ip>     bind address          default: 0.0.0.0 (all interfaces)" + #CRLF$
  msg + "  /p:<port>   port number           default: 8080" + #CRLF$
  msg + "  /t:<token>  upload token          default: empty (open access)" + #CRLF$
  msg + "  /s          auto-start on launch" + #CRLF$
  msg + "  /h          hidden mode (no window), implies /s" + #CRLF$
  msg + "  /l          log to wserv.log next to exe" + #CRLF$
  msg + "  /l:<path>   log to specified file" + #CRLF$
  msg + "  /?          show this help and exit" + #CRLF$
  msg + #CRLF$
  msg + "EXAMPLES" + #CRLF$
  msg + "  wserv.exe /a:192.168.1.10 /p:9000 /t:secret /s" + #CRLF$
  msg + "  wserv.exe /h /t:secret /l:C:" + Chr(92) + "logs" + Chr(92) + "wserv.log" + #CRLF$
  msg + #CRLF$
  msg + "Files are stored in www" + Chr(92) + " subfolder next to the exe." + #CRLF$
  msg + "Token check is skipped when token is empty (open mode)." + #CRLF$
  msg + "Max upload size: 16 MB."
  MessageRequester("wserv Help", msg, #PB_MessageRequester_Ok | #PB_MessageRequester_Info)
EndProcedure

; Populate the IP combo box with all local IPv4 addresses.
; "0.0.0.0" (listen on all interfaces) is always the first choice.
Procedure FillIPCombo()
  Protected ip.s, addr.i
  AddGadgetItem(#CmbIP, -1, "0.0.0.0")  ; always offer "all interfaces" first
  If ExamineIPAddresses()
    Repeat
      addr = NextIPAddress()
      If addr = 0 : Break : EndIf
      ; Assemble the dotted-decimal string from the four octets.
      ip = Str(IPAddressField(addr, 0)) + "." + Str(IPAddressField(addr, 1)) + "." +
           Str(IPAddressField(addr, 2)) + "." + Str(IPAddressField(addr, 3))
      If ip <> "0.0.0.0"
        AddGadgetItem(#CmbIP, -1, ip)
      EndIf
    ForEver
  EndIf
  SetGadgetState(#CmbIP, 0)  ; pre-select "0.0.0.0"
EndProcedure

; Update the window controls to match the current server state.
; Disables/enables controls so the user cannot change settings while running.
Procedure UpdateGui()
  Protected urlIP.s
  If ServerRunning
    UploadToken = GetGadgetText(#EdtToken)  ; snapshot the token at start time
    SetGadgetText(#LblStatus, "Status: RUNNING  |  token: " + UploadToken)
    DisableGadget(#BtnStart,    #True)
    DisableGadget(#BtnStop,     #False)
    DisableGadget(#EdtToken,    #True)
    DisableGadget(#CmbIP,       #True)
    DisableGadget(#EdtPort,     #True)
    ; Lock the logging controls while the server is running so the path
    ; cannot be changed mid-session.
    DisableGadget(#ChkLog,      #True)
    DisableGadget(#EdtLogPath,  #True)
    DisableGadget(#BtnLogBrowse,#True)
    ; Show a clickable-looking URL. If bound to 0.0.0.0, show 127.0.0.1 instead.
    urlIP = BindIP
    If urlIP = "0.0.0.0" : urlIP = "127.0.0.1" : EndIf
    SetGadgetText(#LblUrl, "URL: http://" + urlIP + ":" + Str(ServerPort) + "/")
  Else
    SetGadgetText(#LblStatus, "Status: STOPPED")
    SetGadgetText(#LblUrl, "")
    DisableGadget(#BtnStart,    #False)
    DisableGadget(#BtnStop,     #True)
    DisableGadget(#EdtToken,    #False)
    DisableGadget(#CmbIP,       #False)
    DisableGadget(#EdtPort,     #False)
    ; Restore logging controls. The path field and Browse are only useful
    ; when the checkbox is ticked, so keep them grayed when it is not.
    DisableGadget(#ChkLog, #False)
    If GetGadgetState(#ChkLog) = 0
      DisableGadget(#EdtLogPath,  #True)
      DisableGadget(#BtnLogBrowse,#True)
    Else
      DisableGadget(#EdtLogPath,  #False)
      DisableGadget(#BtnLogBrowse,#False)
    EndIf
  EndIf
EndProcedure

; Read the IP and port from the GUI controls and start the TCP server.
Procedure StartServer()
  Protected portVal.i
  If ServerRunning : ProcedureReturn : EndIf
  portVal = Val(GetGadgetText(#EdtPort))
  If portVal < 1 Or portVal > 65535 : portVal = 8080 : EndIf  ; fall back to 8080 if invalid
  ServerPort = portVal
  BindIP     = GetGadgetText(#CmbIP)
  If BindIP = "" : BindIP = "0.0.0.0" : EndIf
  ; Binding to 0.0.0.0 means "accept connections on any interface".
  ; Binding to a specific IP restricts the server to that interface only.
  If BindIP = "0.0.0.0"
    ServerID = CreateNetworkServer(#PB_Any, ServerPort)
  Else
    ServerID = CreateNetworkServer(#PB_Any, ServerPort, #PB_Network_IPv4 | #PB_Network_TCP, BindIP)
  EndIf
  If ServerID = 0
    MessageRequester("Error", "Cannot bind " + BindIP + ":" + Str(ServerPort))
    ServerRunning = #False
  Else
    ServerRunning = #True
    ; Open the log file now, reading the checkbox and path from the GUI.
    ; We do this here (not at program start) so the user can toggle it
    ; between server sessions without restarting the program.
    LogEnabled = Bool(GetGadgetState(#ChkLog))
    If LogEnabled
      LogPath = GetGadgetText(#EdtLogPath)
      If LogPath = "" : LogPath = GetPathPart(ProgramFilename()) + "wserv.log" : EndIf
      LogFile = OpenFile(#PB_Any, LogPath, #PB_File_Append | #PB_File_SharedRead)
      If LogFile = 0 : LogFile = CreateFile(#PB_Any, LogPath, #PB_File_SharedRead) : EndIf
      If LogFile = 0
        MessageRequester("Warning", "Cannot open log file:" + #CRLF$ + LogPath)
        LogEnabled = #False
      EndIf
    EndIf
    LogHeader()  ; writes session info only if LogEnabled and LogFile > 0
  EndIf
  UpdateGui()
EndProcedure

; Walk every open client buffer and free the memory block inside it.
; ClearMap() only removes map elements; it does NOT free the *mem pointers
; stored inside each ClientBuf structure — we must do that manually.
Procedure FreeAllClientBuffers()
  ForEach ClientBuffers()
    If ClientBuffers()\mem
      FreeMemory(ClientBuffers()\mem)
      ClientBuffers()\mem = 0
    EndIf
  Next
  ClearMap(ClientBuffers())
EndProcedure

; Stop the server, free all buffers, and update the GUI.
; The log file is closed here so it is cleanly flushed and released.
; This lets the user change the log path between sessions.
Procedure StopServer()
  If ServerRunning = #False : ProcedureReturn : EndIf
  LogWrite("--- Server stopped ---")
  FreeAllClientBuffers()
  CloseNetworkServer(ServerID)
  ServerID = 0 : ServerRunning = #False
  ; Close the log file so it can be moved/renamed while the server is stopped.
  If LogFile : CloseFile(LogFile) : LogFile = 0 : EndIf
  LogEnabled = #False  ; will be re-read from the checkbox on next StartServer()
  UpdateGui()
EndProcedure

; ---------------------------------------------------------------
; Command line parsing
; Runs at program start, before the window is created.
; ---------------------------------------------------------------

; These globals are populated from the command line arguments and then
; applied to the GUI gadgets once the window and controls exist.
Global CmdIP.s     = ""
Global CmdPort.i   = 0
Global CmdToken.s  = ""
Global CmdStart.i  = #False
Global CmdHidden.i = #False

Define ci.i, ca.s

; Check for help flags before processing any other arguments.
; If found, show the help dialog and exit immediately.
For ci = 1 To CountProgramParameters()
  ca = LCase(Trim(ProgramParameter(ci - 1)))
  If ca = "?" Or ca = "/?" Or ca = "-help" Or ca = "--help"
    ; We need a minimal window for MessageRequester to work on some Windows versions.
    OpenWindow(#WinMain, 0, 0, 1, 1, "", #PB_Window_Invisible)
    ShowHelp()
    End
  EndIf
Next

For ci = 1 To CountProgramParameters()
  ca = ProgramParameter(ci - 1)
  ; Parse arguments that have a value after the colon: /a:192.168.1.1
  Select LCase(Left(ca, 3))
    Case "/a:" : CmdIP    = Mid(ca, 4)            ; bind IP address
    Case "/p:" : CmdPort  = Val(Mid(ca, 4))        ; port number
    Case "/t:" : CmdToken = Mid(ca, 4)             ; upload token
    Case "/l:" : LogEnabled = #True : LogPath = Mid(ca, 4)  ; log file path
  EndSelect
  ; Parse flag arguments that have no value: /s /h /l
  Select LCase(ca)
    Case "/s" : CmdStart  = #True                  ; auto-start server on launch
    Case "/h" : CmdHidden = #True : CmdStart = #True  ; hidden mode implies auto-start
    Case "/l" : LogEnabled = #True                 ; log to default wserv.log
  EndSelect
  CmdLine + ca + " "  ; accumulate the full command line for the log header
Next

; ---------------------------------------------------------------
; Create the main window
; ---------------------------------------------------------------

; In hidden mode (/h) we still need a window because PureBasic's event loop
; requires one, but we make it invisible so nothing appears on the taskbar.
If CmdHidden
  If OpenWindow(#WinMain, 0, 0, 500, 220, "PB Web Server", #PB_Window_Invisible) = 0 : End : EndIf
Else
  If OpenWindow(#WinMain, 0, 0, 500, 220, "PB Web Server", #PB_Window_SystemMenu | #PB_Window_ScreenCentered) = 0
    MessageRequester("Error", "Cannot open window") : End
  EndIf
EndIf

; Create all controls. Positions are in pixels (x, y, width, height).
ButtonGadget(#BtnStart,  16,  12, 120, 30, "Start")
ButtonGadget(#BtnStop,  148,  12, 120, 30, "Stop")
ButtonGadget(#BtnClose, 280,  12, 100, 30, "Close")
ButtonGadget(#BtnHelp,  388,  12,  80, 30, "Help")  ; opens the help dialog
TextGadget(#LblStatus,   16,  54, 470, 20, "Status: STOPPED")
TextGadget(#LblUrl,      16,  74, 470, 20, "")
TextGadget(#LblIpLabel,  16, 108,  40, 22, "IP:")
ComboBoxGadget(#CmbIP,   60, 106, 180, 24)
TextGadget(#LblPortLabel, 252, 108, 40, 22, "Port:")
StringGadget(#EdtPort,  296, 106,  70, 24, "8080")
TextGadget(#LblTokenLabel, 16, 142, 60, 22, "Token:")
StringGadget(#EdtToken,  80, 140, 200, 24, "")

; Fill the IP combo box with all addresses found on this machine.
FillIPCombo()

; Row 6: logging controls.
; The checkbox toggles logging on/off. The path field shows the log file path.
; Browse opens a save-file dialog to pick a different location.
; All three are disabled while the server is running.
CheckBoxGadget(#ChkLog,      16, 178,  50, 22, "Log")
StringGadget(#EdtLogPath,    70, 176, 292, 24, GetPathPart(ProgramFilename()) + "wserv.log")
ButtonGadget(#BtnLogBrowse, 368, 176, 110, 24, "Browse...")

; Apply /l flag to the logging checkbox and path field.
; The log file itself is opened in StartServer() and closed in StopServer().
If LogEnabled
  SetGadgetState(#ChkLog, #True)  ; tick the checkbox
  If LogPath <> ""
    SetGadgetText(#EdtLogPath, LogPath)  ; fill in the path from /l:<path>
  EndIf
EndIf

; Apply command line values to the GUI controls now that they exist.
If CmdPort > 0 And CmdPort < 65536
  SetGadgetText(#EdtPort, Str(CmdPort))
EndIf
If CmdToken <> ""
  SetGadgetText(#EdtToken, CmdToken)
EndIf
If CmdIP <> ""
  ; Try to select the requested IP in the combo box.
  ; If it is not in the list (e.g. a virtual IP), add it.
  Define ciFound.i = #False
  Define cci.i
  For cci = 0 To CountGadgetItems(#CmbIP) - 1
    If GetGadgetItemText(#CmbIP, cci) = CmdIP
      SetGadgetState(#CmbIP, cci)
      ciFound = #True
      Break
    EndIf
  Next
  If Not ciFound
    AddGadgetItem(#CmbIP, -1, CmdIP)
    SetGadgetState(#CmbIP, CountGadgetItems(#CmbIP) - 1)
  EndIf
EndIf

; Refresh the control states to match the initial stopped condition.
UpdateGui()

; If /s or /h was passed, start the server immediately without user interaction.
If CmdStart : StartServer() : EndIf

; ---------------------------------------------------------------
; Main event loop — runs until the window is closed
; ---------------------------------------------------------------

Define ev.i, cl.i, staleNow.i

Repeat
  ; Drain all pending GUI events before checking the network.
  ; This keeps the UI responsive even when many requests arrive at once.
  Repeat
    ev = WindowEvent()
    Select ev
      Case #PB_Event_CloseWindow : Break 2  ; X button or Alt+F4
      Case #PB_Event_Gadget
        Select EventGadget()
          Case #BtnStart : StartServer()
          Case #BtnStop  : StopServer()
          Case #BtnClose : Break 2
          Case #BtnHelp  : ShowHelp()  ; show help dialog
          Case #ChkLog
            ; When the user ticks/unticks the Log checkbox, immediately
            ; enable or disable the path field and Browse button to give
            ; clear visual feedback about what will happen on Start.
            If GetGadgetState(#ChkLog)
              DisableGadget(#EdtLogPath,   #False)
              DisableGadget(#BtnLogBrowse, #False)
            Else
              DisableGadget(#EdtLogPath,   #True)
              DisableGadget(#BtnLogBrowse, #True)
            EndIf
          Case #BtnLogBrowse
            ; Open a save-file dialog so the user can choose where to write
            ; the log. We default to the current value in the path field.
            ; SaveFileRequester needs 4 args: title, initial path, filter, default filter index.
            Define newPath.s
            newPath = SaveFileRequester("Choose log file", GetGadgetText(#EdtLogPath), "Log files (*.log)|*.log|All files (*.*)|*.*", 0)
            If newPath <> ""
              SetGadgetText(#EdtLogPath, newPath)
            EndIf
        EndSelect
    EndSelect
  Until ev = 0  ; keep processing until there are no more events queued

  If ServerRunning
    ; Check for a network event from any connected client.
    Select NetworkServerEvent()

      Case #PB_NetworkEvent_Connect
        ; A new client just connected. Cache its IP address right now while
        ; the socket is still open, so we can log it even after disconnect.
        cl = EventClient()
        If cl : ClientIPs(Str(cl)) = SocketToIP(cl) : EndIf

      Case #PB_NetworkEvent_Data
        ; The client sent some bytes. Accumulate them and process if complete.
        cl = EventClient()
        If cl : ClientAppendAndCheck(cl) : EndIf

      Case #PB_NetworkEvent_Disconnect
        ; The client closed the connection. Process any buffered data and clean up.
        cl = EventClient()
        If cl : ClientDisconnect(cl) : EndIf
        DeleteMapElement(ClientIPs(), Str(cl))  ; remove the cached IP

    EndSelect

    ; Stale client check: evict any client that sent headers but no body
    ; and never disconnected after 30 seconds of inactivity.
    ; We close the TCP connection explicitly so the socket is not left hanging.
    staleNow = Date()
    ForEach ClientBuffers()
      If ClientBuffers()\lastActivity > 0 And (staleNow - ClientBuffers()\lastActivity) > 30
        LogWrite("(stale) evicted buffer for client " + MapKey(ClientBuffers()))
        CloseNetworkConnection(Val(MapKey(ClientBuffers())))  ; close the actual socket
        DeleteMapElement(ClientIPs(), MapKey(ClientBuffers()))  ; remove cached IP
        If ClientBuffers()\mem : FreeMemory(ClientBuffers()\mem) : EndIf
        DeleteMapElement(ClientBuffers())
      EndIf
    Next

    ; Small sleep so the OS scheduler gets CPU time between event polls.
    ; 1 ms is enough to prevent busy-spin without adding noticeable latency.
    Delay(1)

  Else
    ; Server is stopped. Sleep briefly so we do not burn CPU in a busy loop.
    If Not CmdHidden : Delay(20) : EndIf
  EndIf

ForEver

; ---------------------------------------------------------------
; Cleanup before exit
; ---------------------------------------------------------------

If ServerRunning : StopServer() : EndIf  ; flush log and free buffers
If LogFile  : CloseFile(LogFile)     : EndIf  ; close the log file handle
End

; IDE Options = PureBasic 6.30 (Windows - x86)
; Folding = --
; EnableXP
; Executable = wserv.exe
