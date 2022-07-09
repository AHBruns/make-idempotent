require "set"

RSpec.describe MakeIdempotent do
  it "has a version number" do
    expect(MakeIdempotent::VERSION).not_to be nil
  end

  it "handles worst case" do
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
  end
end
