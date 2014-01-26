###

dnsnmc
http://dnsnmc.net

Copyright (c) 2013 Greg Slepak
Licensed under the BSD 3-Clause license.

###

# TODO: go through 'TODO's!

module.exports = (dnsnmc) ->
    # expose these into our namespace
    for k of dnsnmc.globals
        eval "var #{k} = dnsnmc.globals.#{k};"

    ResolverStream = require('./resolver-stream')(dnsnmc)

    QTYPE_NAME = dns2.consts.QTYPE_TO_NAME
    NAME_QTYPE = dns2.consts.NAME_TO_QTYPE
    NAME_RCODE = dns2.consts.NAME_TO_RCODE
    RCODE_NAME = dns2.consts.RCODE_TO_NAME

    class DNSServer
        constructor: (@dnsnmc) ->
            # @log = @dnsnmc.log.child server: "DNS"
            @log = @dnsnmc.newLogger 'DNS'
            @log.debug "Loading DNSServer..."

            # localize some values from the parent DNSNMC server (to avoid extra typing)
            _.assign @, _.pick(@dnsnmc, ['dnsOpts', 'nmc'])

            @server = dns2.createServer() or tErr "dns2 create"
            @server.on 'socketError', (err) => @error('socketError', err)
            @server.on 'request', @callback.bind(@)
            @server.serve(@dnsOpts.port, @dnsOpts.host)
            @log.info 'started DNS', {opts: @dnsOpts}

        shutdown: ->
            @log.debug 'shutting down!'
            @server.close()

        error: (type, err) ->
            @log.error {type:type, err: err}
            if util.isError(err) then throw err else tErr err

        namecoinizeDomain: (domain) ->
            nmcDomain = S(domain).chompRight('.bit').s
            if (dotIdx = nmcDomain.indexOf('.')) != -1
                nmcDomain = nmcDomain.slice(dotIdx+1) # rm subdomain
            'd/' + nmcDomain # add 'd/' namespace

        oldDNSLookup: (q, res) ->
            sig = "oldDNS{#{@dnsOpts.oldDNSMethod}}"
            @log.debug {fn:sig+'[start]', q:q}

            if @dnsOpts.oldDNSMethod is consts.oldDNS.nativeDNSModule
                req = dns2.Request {question: q, server: @dnsOpts.oldDNS}
                success = false

                req.on 'message', (err, answer) =>
                    if err?
                        @log.error "should not have an error here!", {fn:sig+'[error]', err:err, answer:answer}
                        req.DNSErr ?= err
                    else
                        success = true
                        res.answer.push answer.answer...
                        @log.debug {fn:sig+'[success]', answer:res.answer, q:q}
                        res.send()
                
                req.on 'error', (err) =>
                    @log.error {fn:sig+'[error]', err:err, answer:answer}
                    req.DNSErr = err

                # TODO: find out why some requests appear to be getting lost!
                #       (you can tell something is off cause a whole lot more
                #       appears when using node method)

                req.on 'end', =>
                    unless success
                        @log.warn {fn:sig+'[fail]', q:q, err:req.DNSErr}
                        @sendErr res
                    @log.debug {fn:sig+'[end]', q:q}

                req.send()
            else
                dns.resolve q.name, QTYPE_NAME[q.type], (err, addrs) =>
                    if err
                        @log.warn {fn:sig+'[fail]', q:q, err:err}
                        @sendErr res
                    else
                        # addrs.forEach (a)-> res.answer.push ip2type(q.name, ttl)(a)
                        res.answer.push (addrs.map ip2type(q.name, ttl, QTYPE_NAME[q.type]))...
                        @log.debug {fn:sig+'[success]', answer:res.answer, q:q.name}
                        res.send()


        sendErr: (res, code) ->
            res.header.rcode = code ? NAME_RCODE.SERVFAIL
            @log.warn {fn:'sendErr', code:RCODE_NAME[code]}
            res.send()

        callback: (req, res) ->
            # answering multiple questions in a query appears to be problematic,
            # and few servers do it, so we only answer the first question:
            # https://stackoverflow.com/questions/4082081/requesting-a-and-aaaa-records-in-single-dns-query
            q = req.question[0]
            # TODO: pick an appropriate TTL value
            ttl = Math.floor(Math.random() * 3600) + 30
            @log.debug "received question", {q:q}

            # for now we only handle A types.
            # TODO: handle AAAA for IPv6!
            # if q.type != NAME_QTYPE.A
            #     @log.debug "only support 'A' types ATM, deferring request!", {q:q}
            #     @oldDNSLookup(q, res)

            if S(q.name).endsWith '.bit'
                nmcDomain = @namecoinizeDomain q.name
                @nmc.name_show nmcDomain, (err, result) =>
                    if err
                        @log.error {fn:'nmc_show', err:err, result:result, q:q}
                        @sendErr res
                    else
                        @log.debug {fn:'nmc_show', q:q, result:result}

                        try
                            info = JSON.parse result.value
                        catch e
                            @log.warn "bad JSON!", {err:e, result:result, q:q}
                            return @sendErr res, NAME_RCODE.FORMERR

                        # TODO: handle all the types specified in the specification!
                        #       https://github.com/namecoin/wiki/blob/master/Domain-Name-Specification-2.0.md
                        # TODO: handle other info outside of the specification!
                        #       - GNS support
                        #       - DNSSEC/DANE support?

                        # According to NMC specification, specifying 'ns'
                        # overrules 'ip' value, so check it here and resolve using
                        # old-style DNS.
                        if info.ns?.length > 0
                            # 1. Create a stream of nameserver IP addresses out of info.ns
                            # 2. Send request to each of the servers, separated by a two
                            #    second delay. On receiving the first answer from any of
                            #    them, cancel all other pending requests and respond to
                            #    our client.
                            # 
                            # TODO: handle ns = IPv6 addr!
                            [nsIPs, nsCNAMEs] = [[],[]]

                            for ip in info.ns
                                (if net.isIP(ip) then nsIPs else nsCNAMEs).push(ip)

                            # ResolverStream will clone 'resolvOpts' in the constructor
                            nsCNAME2IP = new ResolverStream(resolvOpts = log:@log)

                            nsIPs = es.merge(sa(nsIPs), sa(nsCNAMEs).pipe(nsCNAME2IP))

                            # safe to do becase ResolverStream clones the opts
                            resolvOpts.stackedDelay = 1000
                            resolvOpts.reqMaker = (nsIP) =>
                                req = dns2.Request
                                    question: q
                                    server: {address: nsIP}

                            stackedQuery = new ResolverStream resolvOpts
                            stackedQuery.errors = 0

                            nsIPs.on 'data', (nsIP) ->
                                stackedQuery.write nsIP

                            stackedQuery.on 'error', (err) =>
                                if ++stackedQuery.errors == info.ns.length
                                    @log.warn "errors on all NS!", {fn:'nmc_show', q:q, err:err}
                                    @sendErr(res)

                            stackedQuery.on 'answers', (answers) =>
                                nsCNAME2IP.cancelRequests(true)
                                stackedQuery.cancelRequests(true)
                                res.answer.push answers...
                                @log.debug "sending answers!", {fn:'nmc_show', answers:answers, q:q}
                                res.send()

                        else if info.ip
                            # we have its IP! send reply to client
                            # TODO: pick an appropriate 'ttl' for the response!
                            # TODO: handle more info! send the rest of the
                            #       stuff in 'info', and all the IPs!
                            info.ip = [info.ip] if typeof info.ip is 'string'
                            # info.ip.forEach (a)-> res.answer.push ip2type(q.name, ttl)(a)
                            res.answer.push (info.ip.map ip2type(q.name, ttl, QTYPE_NAME[q.type]))...
                            @log.debug {fn:'nmc_show|ip', q:q, answer:res.answer}
                            res.send()
                        else
                            @log.warn {fn: 'nmc_show|404', q:q}
                            @sendErr res, NAME_RCODE.NOTFOUND
            
            else if S(q.name).endsWith '.nmc'
                res.answer.push ip2type(q.name,ttl,QTYPE_NAME[q.type])(externalIP())
                @log.debug {fn:'.nmc', d:q.name, answer:res.answer}
                res.send()
            else
                @log.debug "deferring question", {q:q}
                @oldDNSLookup(q, res)
