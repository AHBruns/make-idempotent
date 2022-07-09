require "json"

require_relative "make_idempotent/version"

module MakeIdempotent
  class Error < StandardError; end
  class RequestAlreadySendingError < Error; end
  class RequestAlreadySentError < Error; end
  class InconclusiveRequestError < Error; end

  class RequestSender
    # send_request: Takes a request_description and returns the request's
    # result. If the request is inconclusive, e.g. a timeout, send_request must
    # throw InconclusiveRequestError.
    #
    # check_if_request_received: Takes a request_description and returns either true
    # or false depending on if the request was received before. Normally this
    # will mean querying the same service the request was sent to. In
    # situations where there is no way to determine if a request was received
    # before check_if_request_received can either throw an error to stop the program
    # until a human can determine the best course of action, or it can return
    # either true while logging to some external service that a request may not
    # have actually been received, or it can return false while logging to some
    # external service that a request may have been double delivered.
    #
    # store: Takes a request_description and stores it in some persistent
    # datastore. If the datastore already contains the given
    # request_description, store must throw RequestAlreadySendingError.
    #
    # unstore: Takes a request_description and removes it from the persistent
    # datastore. If the datastore doesn't contain the given request_description
    # it should act as if the delete was successful.
    def initialize(
      send_request:,
      check_if_request_received:,
      store:,
      unstore:
    )
      @send_request = send_request
      @check_if_request_received = check_if_request_received
      @store = store
      @unstore = unstore
    end

    # This method is idempotent so long as it is never called more than once at
    # any given a time, and is never called with the same request_description
    # after a previous call completed without raising
    # an InconclusiveRequestError. That is, only one request can ever be
    # in-flight at any given time, and once you get a result for a request you
    # never send the same request again.
    # 
    # Finally, subsequent calls are technically not idempotent due to the
    # possibility of network race conditions, but this possibility becomes
    # increasingly less likely as the time between calls increases. However, it
    # is never 0. If you need a strong idempotency guarantee, you need the
    # receiver to actually implement an idempotent API.
    def send_request(request_description)
      begin
        @store.call(request_description)
      rescue => exception
        if exception.is_a?(RequestAlreadySendingError)
          if @check_if_request_received.call(request_description)
            @unstore.call(request_description)
            raise RequestAlreadySentError.new
          end
        else
          raise exception
        end
      end

      begin
        response = @send_request.call(request_description)
      rescue => exception
        raise exception if exception.is_a?(InconclusiveRequestError)

        @unstore.call(request_description)
        raise exception      
      end
    end
  end

  class RequestSenderFactory
    def initialize(store:, unstore:)
      @store = store
      @unstore = unstore
    end

    def make_request_sender(send_request:, check_if_request_received:)
      new RequestSender(
        send_request: send_request,
        check_if_request_received: check_if_request_received,
        store: @store,
        unstore: @unstore
      )
    end
  end
end
