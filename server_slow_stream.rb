#!/usr/bin/env ruby
# frozen_string_literal: true

# Server that sends one message then hangs (like a stuck Spanner partition)

require "grpc"
require_relative "my_service_services_pb"

class SlowGreeter < MyService::Greeter::Service
  def say_hello(hello_req, _unused_call)
    name = hello_req.name
    return MyService::HelloReply.new(message: "Hello, #{name}!")
  end
  
  def stream_numbers(hello_req, _unused_call)
    name = hello_req.name
    
    Enumerator.new do |yielder|
      # Send first message
      puts "[Server] Sending message 1..."
      yielder << MyService::HelloReply.new(message: "Message 1 for #{name}")
      
      # Now hang indefinitely (simulating stuck Spanner partition)
      puts "[Server] Now hanging forever (simulating stuck partition)..."
      sleep # Sleep forever
      
      # This will never be reached
      yielder << MyService::HelloReply.new(message: "Message 2 for #{name}")
    end
  end
end

def main
  # Start the gRPC server
  server = GRPC::RpcServer.new
  server.add_http2_port("0.0.0.0:50051", :this_port_is_insecure)
  server.handle(SlowGreeter)

  puts "Slow Streaming Server is running at 0.0.0.0:50051..."
  puts "It will send 1 message then hang (like stuck Spanner partition)"
  server.run_till_terminated
end

# Run the server
main

