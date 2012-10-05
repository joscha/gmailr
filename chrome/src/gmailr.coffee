###
Gmailr v0.0.1
Licensed under The MIT License

Copyright 2012, James Yu, Joscha Feth
###
(($, window) ->

  class XHRWatcher
    initialized: false
    iframeData: {}
    iframeCachedData: []
    _Gmail_open: null
    _Gmail_send: null

    constructor: (cb) ->
      return if @initialized
      self = @
      @initialized = true
      win = top.document.getElementById("js_frame").contentDocument.defaultView

      @_Gmail_open ?= win.XMLHttpRequest::open
      win.XMLHttpRequest::open = (method, url, async, user, password) ->
        @xhrParams =
          method: method.toString()
          url: url.toString()
        self._Gmail_open.apply @, arguments

      @_Gmail_send ?= win.XMLHttpRequest::send
      win.XMLHttpRequest::send = (body) ->
        if @xhrParams
          @xhrParams.body = body
          cb @xhrParams
        self._Gmail_send.apply @, arguments

      top._Gmail_iframeFn ?= top.GG_iframeFn
      @iframeCachedData.push
        responseDataId: 1
        url: top.location.href
        responseData: top.VIEW_DATA

      top.GG_iframeFn = (win, data) ->
        d = top._Gmail_iframeFn.apply @, arguments
        try
          url = win?.location?.href ? null
          if data and url?.indexOf("act=") isnt -1
            unless self.iframeData[url]
              self.iframeData[url] = true
              body = ""
              if (parent = win.frameElement.parentNode)
                tmp = $(parent).find "form"
                body = tmp.first().serialize() if tmp.length > 0

              cb
                body: body
                url: url

        catch e
          try
            dbg "DEBUG error in GG_iframeFn: ", e
        d
  
  # Utility methods
  dbg = (args...) ->
    console.log.apply console, args if console?.log and Gmailr.debug is true

  isDescendant = (el, t) ->
    t.parents().index(el) >= 0

  class Gmailr
    
    debug: false
    priorityInboxLink: null
    currentNumUnread: null
    currentInboxCount: null
    elements: {}
    currentLeftMenuItem: null
    observers: {}
    loaded: false
    inConversationView: false
    xhrWatcher: null
    delayedLoader: null

    EVENT_VIEW_THREAD:        'viewThread'
    EVENT_ARCHIVE:            'archive'
    EVENT_APPLY_LABEL:        'applyLabel'
    EVENT_DELETE:             'delete'
    EVENT_COMPOSE:            'compose'
    EVENT_REPLY:              'reply'
    EVENT_SPAM:               'spam'
    EVENT_DRAFT_DISCARD:      'discardDraft'
    EVENT_DRAFT_SAVE:         'saveDraft'
    EVENT_MARK_UNREAD:        'unread'
    EVENT_MARK_READ:          'read'
    EVENT_STAR:               'star'
    EVENT_UNSTAR:             'unstar'
    EVENT_UNREAD_CHANGE:      'numUnreadChange'
    EVENT_INBOX_COUNT_CHANGE: 'inboxCountChange'
    EVENT_VIEW_CHANGED:       'viewChanged'


    VIEW_CONVERSATION:  'conversation'
    VIEW_THREADED:      'threaded'
    
    #
    #            This is the main initialization routine. It bootstraps Gmailr into the Gmail interface.
    #            You must call this with a callback, like so:
    #
    #            Gmailr.init(funciton(G) {
    #                // .. G is the Gmailr API object
    #            });
    #        
    init: (cb) ->
      if @loaded
        dbg "Gmailr has already been initialized"
        cb? this
        return

      dbg "Initializing Gmailr API"
      # Here we do delayed loading until success. This is in the case
      # that our script loads after Gmail has already loaded.
      load = =>
        @elements.canvas = $("[style*='min-height: 100%;']")
        @elements.body = @elements.canvas.find(".nH").first()
        if @loaded
          clearInterval @delayedLoader
          dbg "Delayed loader success."
          @elements.body.bind 'DOMSubtreeModified', @detectDOMEvents
        else
          dbg "Calling delayed loader..."      
          # we search from the body node, since there's no event to attach to
          @bootstrap cb
        return

      @delayedLoader = setInterval load, 500
      return

    ###
    This method attempts to bootstrap Gmailr into the Gmail interface.
    Basically, this amounts polling to make sure Gmail has fully loaded,
    and then setting up some basic hooks.
    ###
    bootstrap: (cb) ->
      if @inBootstrap
        return
      @inBootstrap = true
      if @elements.body
        el = $(@elements.body)
        
        # get handle on the left menu
        if not @leftMenu or @leftMenu.length is 0
          
          #                  this.leftMenu = el.find('.no .nM .TK').first().closest('.nn');
          inboxLink = @getInboxLink()
          v = el.find("a[href$='#mbox']")
          @priorityInboxLink = v.first()  if v.length > 0
          if inboxLink
            @leftMenu = inboxLink.closest(".TO").closest("div")
          else @leftMenu = @priorityInboxLink.closest(".TO").closest("div")  if @priorityInboxLink
          if @leftMenu and @leftMenu.length > 0
            @leftMenuItems = @leftMenu.find(".TO")
            dbg "Fully loaded."
            @loaded = true
            @currentNumUnread = @numUnread()
            @currentInboxCount = @toolbarCount()  if @inboxTabHighlighted()
            @xhrWatcher = new XHRWatcher @detectXHREvents
            cb? this
        @inBootstrap = false
        return

    intercept: ->
      throw "Call to method before Gmail has loaded" unless @loaded
      return
    
    #
    #            Inserts the element to the top of the Gmail interface.
    #        
    insertTop: (el) ->
      @intercept()
      @elements.body.prepend $(el)

    
    #
    #            Allows you to apply jQuery selectors in the Gmail DOM, like so:
    #
    #            G.$('.my_class');
    #        
    $: (selector) ->
      @intercept()
      @elements.body.find selector

    
    ###
    Subscribe to a specific event in Gmail
    name                arguments passed to callback
    'archive'         - count
    'numUnreadChange' - currentVal, previousVal
    'delete'          - count
    'spam'            - count
    'compose'
    'viewChanged'
    'applyLabel'
    ###
    observe: (type, cb) ->
      (@observers[type] ?= []).push cb

    notify: (type, args...) ->
      if @observers[type]
        for listener in @observers[type]
          listener?.apply? @, args
      return

    
    ###
    Number of unread messages.
    ###
    numUnread: ->
      @intercept()
      
      # We always look to the inbox link, bc it always displays the number unread
      # no matter where you are in Gmail
      
      #var title = this.inboxLink[0].title;
      title = @getInboxLink()[0].title
      m = /\((\d+)\)/.exec(title)
      parseInt(m?[1]? ? 0)

    
    ###
    Email address of the Gmail account.
    ###
    emailAddress: ->
      @intercept()
      # First, try old Gmail header
      # Try the new one
      selectors = ["#guser b", ".gbmp1", "#gbi4t"] # Google+ (as of 2012-10-05)
      el = @elements.canvas.find selectors.join ','
      el.first().html()

    
    ###
    Returns whether the current view is a threaded or conversation view.
    ###
    currentView: ->
      @intercept()
      if @elements.canvas.find("h1.ha").length > 0 then @VIEW_CONVERSATION else @VIEW_THREADED

    getInboxLink: ->
      # use the inbox link as an anchor
      v = $(@elements.body).find "a[href$='#inbox'][title^='Inbox']"
      v.first() or null

    liveLeftMenuItem: ->
      return null  unless @loaded
      el = @leftMenuItems.filter(".nZ").find("a")
      if el[0]
        el[0].title
      else
        null

    inboxTabHighlighted: ->
      @currentTabHighlighted() is "inbox" or @currentTabHighlighted() is "priority_inbox"

    currentTabHighlighted: ->
      inboxLink = @getInboxLink()
      if inboxLink and inboxLink.closest(".TO").hasClass("nZ")
        "inbox"
      else if @priorityInboxLink and @priorityInboxLink.closest(".TO").hasClass("nZ")
        "priority_inbox"
      else
        null

    
    # Return true if a yellow archive highlight actually means the user is archiving
    archiveableState: ->
      
      # For threads, this overrestricts:
      #   TODO: should detect if user is archiving an inbox item from a non-inbox view
      # For conversations, this underrestricts:
      #   TODO: should detect if the current email is in the inbox, and only assign points if it is
      (@inboxTabHighlighted() and @currentView() is @VIEW_THREADED) or (@currentView() isnt @VIEW_THREADED)

    mainListingEl: ->
      @elements.canvas.find(".nH.Cp").first()

    mainListingEmpty: ->
      if @mainListingEl().length > 0 and @currentView() is @VIEW_THREADED
        @mainListingEl().find("table tr").length is 0
      else
        null

    toolbarEl: ->
      @elements.canvas.find(".A1.D.E").first()

    toolbarCount: ->
      el = @toolbarEl().find(".Dj")
      if el[0]
        t = el[0].innerHTML
        m = /of <b>(\d+)<\/b>/.exec(t)
        if m?[1]? then parseInt m[1] else null
      else
        if @mainListingEmpty() then 0 else null

    toEmailProps: (postParams) ->
      inReplyTo: (if postParams.rm is "undefined" then null else postParams.rm)
      body: postParams.body ? null
      subject: postParams.subject ? null
      bcc: @toEmailArray postParams.bcc
      to: @toEmailArray postParams.to
      from: postParams.from
      isHTML: postParams.ishtml is '1'
      cc: @toEmailArray postParams.cc
      fromDraft: (if postParams.draft is "undefined" then null else postParams.draft)

    # Adapted from http://notepad2.blogspot.com/2012/02/javascript-parse-string-of-email.html
    toEmailArray: (str) ->
      return [] if !str
      regex = /(?:"([^"]+)")? ?<?(.*?@[^>,]+)>?,? ?/g;
      while (m = regex.exec str)
          name:  m[1]
          email: m[2]

    detectXHREvents: (params) =>
      try
        urlParams = $.deparam params.url
        action = urlParams.act ? urlParams.view
        count = 1
        postParams = null
        if params.body.length > 0
          postParams = $.deparam params.body
          if postParams and postParams.t and !(postParams.t instanceof Array)
            postParams.t = [postParams.t]
            count = postParams.t.length
          
          # The user has cleared more than a pageful, so we don't know the exact count
          count = -1  if postParams["ba"]

        switch action

          # View thread
          when "ad"
            dbg "User views a thred"
            @notify @EVENT_VIEW_THREAD, urlParams.th

          # Archiving
          when "rc_^i"
            # only count if from inbox or query
            # TODO: could do better
            if urlParams.search in ["inbox", "query", "cat", "mbox"]
              if postParams
                  dbg "User archived emails."
                  @notify @EVENT_ARCHIVE, count, postParams.t
                #delete emailsArchived

          #Applying label
          when "arl"
            label = urlParams["acn"]
            @notify @EVENT_APPLY_LABEL, label, count, postParams.t

          # Deleting
          when "tr"
            dbg "User deleted #{count} emails."
            @notify @EVENT_DELETE, count, postParams.t

          # Composing
          when "sm"
            if @currentView() is @VIEW_CONVERSATION
              dbg "User replied to an email."
              @notify @EVENT_REPLY, @toEmailProps postParams
            else
              dbg "User composed an email."
              @notify @EVENT_COMPOSE, @toEmailProps postParams

          # Spam
          when "sp"
            dbg "User spammed #{count} emails."
            @notify @EVENT_SPAM, count, postParams.t

          # Discard draft
          when "dr"
            dbg "User discarded? a draft."
            @notify @EVENT_DRAFT_DISCARD

          # Save draft
          when "sd"
            dbg "User saved? a draft."
            @notify @EVENT_DRAFT_SAVE, @toEmailProps postParams

          # Mark unread
          when "ur"
            dbg "User marked messages as unread."
            @notify @EVENT_MARK_UNREAD, count, postParams.t

          # Mark read
          when "rd"
            dbg "User marked messages as read."
            @notify @EVENT_MARK_READ, count, postParams.t

          # Star
          when "st"
            dbg "User starred messages."
            starType = switch postParams.sslbl
                          when "^ss_sy" then "standard"
                          else "unknown"
            @notify @EVENT_STAR, count, postParams.t, starType

          # Unstar
          when "xst"
            dbg "User unstarred messages."
            @notify @EVENT_UNSTAR, count, postParams.t

      catch e
        dbg "Error in detectXHREvents: " + e

      return

    detectDOMEvents: (e) =>
      el = $(e.target)
      
      # Left Menu Changes
      #var s = this.liveLeftMenuItem();
      #            if(this.currentLeftMenuItem != s) {
      #                this.currentLeftMenuItem = s;
      #                this.notify('tabChange', s);
      #            }
      #            
      
      #
      #            // Unread change
      #            var l = this.getInboxLink() || this.priorityInboxLink;
      #            if((el[0] == l[0]) || isDescendant(el, l)) {
      #                var newCount = this.numUnread();
      #                if(this.currentNumUnread != newCount) {
      #                    this.notify(@EVENT_UNREAD_CHANGE, newCount, this.currentNumUnread);
      #                    this.currentNumUnread = newCount;
      #                }
      #            }
      #            
      if @elements.canvas.find(".ha").length > 0
        unless @inConversationView
          @inConversationView = true
          @notify @EVENT_VIEW_CHANGED, @VIEW_CONVERSATION
      else
        if @inConversationView
          @inConversationView = false
          @notify @EVENT_VIEW_CHANGED, @VIEW_THREADED
      
      # Inbox count change
      if isDescendant @toolbarEl(), el
        toolbarCount = @toolbarCount()
        if @inboxTabHighlighted() and toolbarCount
          if (@currentInboxCount is null) or (toolbarCount isnt @currentInboxCount)
            @notify @EVENT_INBOX_COUNT_CHANGE, toolbarCount, @currentInboxCount  if @currentInboxCount isnt null
            @currentInboxCount = toolbarCount


  Gmailr = new Gmailr

  window.Gmailr = Gmailr
  return

) jQuery, window