#!/usr/bin/env ruby
# frozen_string_literal: true

# This demonstrates that SIGINT doesn't interrupt gRPC streaming calls
# Run this with: ruby test_sigint.rb
# You should see it try to interrupt but fail, waiting for timeout instead

require "grpc"
require_relative "my_service_services_pb"

def test_sigint_doesnt_interrupt
  puts "Starting gRPC streaming test..."
  
  stub = MyService::Greeter::Stub.new("localhost:50051", :this_channel_is_insecure)
  request = MyService::HelloRequest.new(name: "Test")
  
  # Start a thread that will send SIGINT after 2 seconds
  interrupt_thread = Thread.new do
    sleep 2
    puts "\n[#{Time.now}] Sending SIGINT to main thread..."
    Process.kill("INT", Process.pid)
    puts "[#{Time.now}] SIGINT sent!"
  end
  
  # Set up SIGINT handler to see if it fires
  sigint_received = false
  Signal.trap("INT") do
    sigint_received = true
    puts "[#{Time.now}] SIGINT handler called on #{Thread.current}! (but gRPC will ignore it)"
    puts caller_locations
  end
  
  puts "[#{Time.now}] Starting to iterate stream on #{Thread.current} (server will hang after 1 message)..."
  
  begin
    responses = stub.stream_numbers(request, deadline: Time.now + 30)
    
    responses.each do |response|
      puts "[#{Time.now}] Received: #{response.message}"
    end
    
    puts "[#{Time.now}] Stream completed normally"
  rescue GRPC::DeadlineExceeded => e
    puts "[#{Time.now}] ❌ DeadlineExceeded: Stream timed out (#{e.message})"
    puts "[#{Time.now}] SIGINT was received: #{sigint_received}"
    puts "[#{Time.now}] But the stream continued until timeout!"
  rescue => e
    puts "[#{Time.now}] Error: #{e.class} - #{e.message}"
  ensure
    interrupt_thread.kill
  end
end

# Run the test
test_sigint_doesnt_interrupt

