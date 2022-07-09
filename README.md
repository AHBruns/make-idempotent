# Make-idempotent

This is a small utility library to generalize the process of combining a non-idempotent request and an idempotent query to create an idempotent request.

# Installation

To install the latest version of this gem run `bundle install make_idempotent` or the equivalent in your ruby gem manager of choice.

# Usage

Easiest way to grok how this works is to read the tests. Here's a good one:

```ruby
server_datastore = { ids: Set[], data: [] }
server_api = {
  mutate: Proc.new do |id, data|
    server_datastore[:ids].add(id)
    server_datastore[:data].append(data)
  end,
  query: Proc.new { |id, _data| server_datastore[:ids].member?(id) }
}

requests_datastore = Set[]
request_sender = MakeIdempotent::RequestSender.new(
  send_request: Proc.new do |id, data|
    # only 25% request gets to the server
    raise MakeIdempotent::InconclusiveRequestError unless rand() > 0.75

    result = server_api[:mutate].call(id, data)

    # only 0.01% of responses get back
    raise MakeIdempotent::InconclusiveRequestError unless rand() > 0.9999

    result
  end,
  check_if_request_received: Proc.new do |id, data|
    # only 25% request gets to the server
    raise MakeIdempotent::InconclusiveRequestError unless rand() > 0.75

    result = server_api[:query].call(id)

    # only 0.01% of responses get back
    raise MakeIdempotent::InconclusiveRequestError unless rand() > 0.9999

    result
  end,
  store: Proc.new do |id, data|
    if (requests_datastore.member?(id))
      raise MakeIdempotent::RequestAlreadySendingError
    end
    requests_datastore.add(id)
  end,
  unstore: Proc.new { |id, data| requests_datastore.delete(id) }
)

while true
  begin
    request_sender.send_request(["idempotency key", "data"])
    break
  rescue => exception
    break if exception.is_a?(MakeIdempotent::RequestAlreadySentError)
    next if exception.is_a?(MakeIdempotent::InconclusiveRequestError)
    raise exception
  end
end

expect(server_datastore[:data]).to eq(["data"])
```

This is the general usecase, but often time you'll want to use the same store and unstore methods across many or all your requests. When this is the case, you can use the following:

```ruby
request_sender = MakeIdempotent::RequestSenderFactory.new(
  store: your_store_implementation,
  unstore: your_unstore_implementation
)
request_sender.send_request(...)
```

# The contract

While the API is simple, the implementer does need to ensure their implementation meets some basic requirements. Here's the contract.

- `store` must persist the request_description it is passed to a datastore before returning. It must be the same datastore that unstore deletes from. If the request_definition already exists in the data store, it must throw `MakeIdempotent::RequestAlreadySendingError`.
- `unstore` must handle unstoring requests that don't exist in its store. It must treat them as successful.
- `send_request` must throw `MakeIdempotent::InconclusiveRequestError` if and only if it is unclear whether the request was processed by the receiver. In most (all?) cases this will be a request timeout.
- `check_if_request_received` must return true if the request has been received, and false if not. It must also be idempotent.
- You may only call `send_request` with the same request_description once at a time. Basically, don't let more than one request go at once. Obviously, this isn't possible if you don't know if the previous request failed. For example, `MakeIdempotent::InconclusiveRequestError` is thrown by a request, or the process crashed in the middle of sending a previous request. In these situations, this library only gives a best effort idempotency guarantee due to the possibility of network race conditions. Though the likelyhood of idempotency goes up as the time between requests increases, it never reaches 100%.
