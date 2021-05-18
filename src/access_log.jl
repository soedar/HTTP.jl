"""
    logfmt"..."

Parse an [NGINX-style log format string](https://nginx.org/en/docs/http/ngx_http_log_module.html#log_format)
and return a function mapping `(io::IO, http::HTTP.Stream) -> body` suitable for passing to
[`HTTP.listen`](@ref) using the `access_logfmt` keyword argument.

The following variables are currently supported:

 - `\$http_name`: arbitrary request header (with `-` replaced with`_`, e.g. `http_user_agent`)
 - `\$sent_http_name`: arbitrary response header (with `-` replaced with`_`)
 - `\$request`: the request line, e.g. `GET /index.html HTTP/1.1`
 - `\$request_method`: the request method
 - `\$request_uri`: the request URI
 - `\$remote_addr`: client adress
 - `\$remote_port`: client port
 - `\$remote_user`: user name supplied with the Basic authentication
 - `\$server_protocol`: server protocol
 - `\$time_iso8601`: local time in ISO8601 format
 - `\$time_local`: local time in Common Log Format
 - `\$status`: response status code
 - `\$body_bytes_sent`: number of bytes in response body

## Examples
```julia
logfmt"[\$time_iso8601] \\"\$request\\" \$status" # [2021-05-01T12:34:40+0100] "GET /index.html HTTP/1.1" 200

logfmt"\$remote_addr \\"\$http_user_agent\\"" # 127.0.0.1 "curl/7.47.0"
```
"""
macro logfmt_str(s)
    return logfmt_parser(s)
end

function logfmt_parser(s)
    s = String(s)
    vars = Symbol[]
    ex = Expr(:call, :print, :io)
    i = 1
    while i <= lastindex(s)
        j = findnext(==('\$'), s, i)
        if j === nothing
            j = lastindex(s)
            push!(ex.args, String(s[i:j]))
            break
        end
        if j > i
            push!(ex.args, String(s[i:prevind(s, j)]))
        end
        sym, j = Meta.parse(s, nextind(s, j); greedy=false)
        e = symbol_mapping(sym)
        isa(e, Tuple) ? push!(ex.args, e...) : push!(ex.args, e)
        i = j
    end
    f = Expr(:->, Expr(:tuple, :io, :http), ex)
    return f
end

function symbol_mapping(s::Symbol)
    str = string(s)
    if (m = match(r"^http_(.+)$", str); m !== nothing)
        hdr = replace(String(m[1]), '_' => '-')
        :(HTTP.header(http.message, $hdr, "-"))
    elseif (m = match(r"^sent_http_(.+)$", str); m !== nothing)
        hdr = replace(String(m[1]), '_' => '-')
        :(HTTP.header(http.message.response, $hdr, "-"))
    elseif s === :remote_addr
        :(Sockets.getpeername(http)[1])
    elseif s === :remote_port
        :(Sockets.getpeername(http)[2])
    elseif s === :remote_user
        :("-") # TODO: find from Basic auth...
    elseif s === :time_iso8601
        :(Libc.strftime("%FT%T%z", time()))
    elseif s === :time_local
        :(Libc.strftime("%d/%b/%Y:%H:%M:%S %z", time()))
    elseif s === :request
        m = symbol_mapping(:request_method)
        t = symbol_mapping(:request_uri) # TODO: should include query?
        p = symbol_mapping(:server_protocol)
        (m, " ", t, " ", p...)
    elseif s === :request_method
        :(http.message.method)
    elseif s === :request_uri
        :(http.message.target)
    elseif s === :server_protocol
        ("HTTP/", :(http.message.version.major), ".", :(http.message.version.minor))
    elseif s === :status
        :(http.message.response.status)
    elseif s === :body_bytes_sent
        return :(http.nwritten)
    else
        error("unknown variable in logfmt: $s")
    end
end

"""
    common_logfmt(io::IO, http::HTTP.Stream)

Format a log message in the Common Log Format and write to `io`.
"""
const common_logfmt = logfmt"$remote_addr - $remote_user [$time_local] \"$request\" $status $body_bytes_sent"

"""
    combined_logfmt(io::IO, http::HTTP.Stream)

Format a log message in the Combined Log Format and write to `io`.
"""
const combined_logfmt = logfmt"$remote_addr - $remote_user [$time_local] \"$request\" $status $body_bytes_sent \"$http_referer\" \"$http_user_agent\""

