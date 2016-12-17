const DEFAULT_CHUNK_SIZE = 2^20

abstract Scheme

immutable http <: Scheme end
immutable https <: Scheme end
# immutable ws <: Scheme end
# immutable wss <: Scheme end

typealias Headers Dict{String,String}

type RequestOptions
    chunksize::Int
    gzip::Bool
    connecttimeout::Float64
    readtimeout::Float64
    tlsconfig::TLS.SSLConfig
    maxredirects::Int
end

function RequestOptions(options::RequestOptions; kwargs...)
    for (k, v) in kwargs
        setfield!(options, k, v)
    end
    return options
end
RequestOptions(; kwargs...) = RequestOptions(RequestOptions(DEFAULT_CHUNK_SIZE, false, 10.0, 9.0, TLS.SSLConfig(true), 5); kwargs...)

type Request{I}
    method::String # HTTP method string (e.g. "GET")
    major::Int8
    minor::Int8
    uri::URI
    headers::Headers
    keepalive::Bool
    body::I # Vector{UInt8}, String, IO
    options::RequestOptions
end

Request(; args...) = Request("GET", Int8(1), Int8(1), URI(""), Headers(), true, Vector{UInt8}(), RequestOptions(; args...))

defaultheaders(::Type{Request}) = Headers(
    "User-Agent" => "HTTP.jl/0.0.0",
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
)

Request(method, uri, userheaders=Headers(), body=UInt8[]; args...) = Request(method, uri, userheaders, body, RequestOptions(; args...))

function Request(method, uri, userheaders, body, options::RequestOptions)
    headers = defaultheaders(Request)

    headers["Host"] = uri.port == 0 ? uri.host : "$(uri.host):$(uri.port)"

    if !isempty(uri.userinfo) && !haskey(headers,"Authorization")
        headers["Authorization"] = "Basic $(base64encode(uri.userinfo))"
    end

    if sizeof(body) > options.chunksize
        # chunked-transfer
        headers["Transfer-Encoding"] = "chunked;" * options.gzip ? " gzip;" : ""
    else
        # just set the Content-Length
        if !(method in ("GET", "HEAD", "CONNECT"))
            headers["Content-Length"] = dec(sizeof(body))
        end
    end
    if !haskey(headers, "Content-Type") && length(body) > 0
        headers["Content-Type"] = HTTP.sniff(body)
    end
    sch = uri.scheme == "http" ? http : https
    return Request(method, Int8(1), Int8(1), uri, merge!(headers, userheaders), true, body, options)
end

==(a::Request,b::Request) = (a.method    == b.method)    &&
                            (a.major     == b.major)     &&
                            (a.minor     == b.minor)     &&
                            (a.uri       == b.uri)       &&
                            (a.headers   == b.headers)   &&
                            (a.keepalive == b.keepalive) &&
                            (a.body      == b.body)

Base.showcompact(io::IO, r::Request) = print(io, "Request(", resource(r.uri), ", ",
                                        length(r.headers), " headers, ",
                                        sizeof(r.body), " bytes in body)")

type Response
    status::Int
    major::Int8
    minor::Int8
    headers::Headers
    keepalive::Bool
    cookies::Vector{Cookie}
    body::FIFOBuffer
    request::Nullable{Request}
    history::Vector{Response}
end

Response() = Response(200, 1, 1, Headers(), true, Cookie[], FIFOBuffer(), Nullable(), Response[])
Response(n, r::Request) = Response(200, 1, 1, Headers(), true, Cookie[], FIFOBuffer(0, n), Nullable(r), Response[])
Response(s::Int) = Response(s, defaultheaders(Response), FIFOBuffer())
Response(body::String) = Response(200, defaultheaders(Response), body)
Response(s::Int, h::Headers, body) =
  Response(s, 1, 1, h, true, Cookie[], body, Nullable(), Response[])

defaultheaders(::Type{Response}) = Headers(
    "Server"            => "Julia/$VERSION",
    "Content-Type"      => "text/html; charset=utf-8",
    "Content-Language"  => "en",
    "Date"              => Dates.format(now(Dates.UTC), Dates.RFC1123Format)
)

==(a::Response,b::Response) = (a.status  == b.status)  &&
                              (a.major   == b.major)   &&
                              (a.minor   == b.minor)   &&
                              (a.headers == b.headers) &&
                              (a.cookies == b.cookies) &&
                              (a.body    == b.body)

function Base.showcompact(io::IO, r::Response)
    print(io, "Response(", r.status, " ", Base.get(STATUS_CODES, r.status, "Unknown Code"), ", ",
          length(r.headers)," headers, ",
          sizeof(r.body)," bytes in body)")
end

headers(r::Union{Request,Response}) = r.headers
history(r::Response) = r.history
cookies(r::Response) = r.cookies
status(r::Response) = r.status
statustext(r::Response) = Base.get(STATUS_CODES, r.status, "Unknown Code")

const CRLF = "\r\n"

## Request & Response writing
# start lines
function startline(io::IO, r::Request)
    write(io, "$(r.method) $(resource(r.uri)) HTTP/$(r.major).$(r.minor)$CRLF")
end

function startline(io::IO, r::Response)
    write(io, "HTTP/$(r.major).$(r.minor) $(r.status) $(statustext(r))$CRLF")
end

# headers
function headers(io::IO, r::Union{Request, Response})
    for (k, v) in headers(r)
        write(io, "$k: $v$CRLF")
    end
    cookies(io, r)
    write(io, CRLF)
end

# cookies
function cookies(io::IO, r::Request)

end

function cookies(io::IO, r::Response)

end

# body
hasmessagebody(r::Request) = length(r.body) > 0

# https://tools.ietf.org/html/rfc7230#section-3.3
function hasmessagebody(r::Response)
    if 100 <= r.status < 300 || r.status == 304
        return false
    elseif !isnull(r.request)
        req = get(r.request)
        if req.method in ("HEAD", "CONNECT")
            return false
        end
    end
    return true
end

function body(io::IO, r::Union{Request, Response})
    hasmessagebody(r) || return
    if sizeof(r.body) > r.options.chunksize
        # chunked-transfer
        totallen = length(r.body)
        transfered = 0
        while transfered < totallen
            chunk = min(r.options.chunksize, totallen - transfered)
            write(io, "$(hex(chunk))$CRLF")
            write(io, view(r.body, (transfered+1):(transfered+chunk)))
            write(io, CRLF)
            transfered += chunk
        end
        write(io, "$(hex(0))$CRLF$CRLF")
    else
        write(io, r.body)
    end
end

function Base.write(io::IO, r::Union{Request, Response})
    startline(io, r)
    headers(io, r)
    body(io, r)
    return
end

function Base.show(io::IO, r::Union{Request,Response})
    println(io, typeof(r), ":")
    println(io, "\"\"\"")
    startline(io, r)
    headers(io, r)
    if length(r.body) > 1000
        println(io, "[Request body of $(length(r.body)) bytes]")
    elseif length(r.body) > 0
        println(io, String(r.body))
    end
    println(io, "\"\"\"")
end
