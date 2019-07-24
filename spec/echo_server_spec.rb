require 'spec_helper'

RSpec.shared_examples "an echo server" do
  it "writes a PID file" do
    expect(File.exist?(echo_pid_path)).to be true
  end

  it "echoes data sent to it" do
    with_connection do |socket|
      message = "hello world!"
      socket.puts(message)
      rtn_data = socket.gets.chomp

      expect(rtn_data).to eq(message)
    end
  end

  context "on recieving TERM" do
    after(:each) do
      # Every test in this block should end with the echo server stopped, so start a new one for the next test
      start_server
    end

    it "quits immediately when no connections are active" do
      Process.kill("TERM", current_echo_pid)
      sleep 0.1 # immediately-ish
      expect(echo_server_running?).to be false
    end

    it "does not quit until all connections are complete" do
      connection_thread = Thread.start do
        with_connection do |socket|
          sleep 1
        end
      end

      # Make sure the thread has had time to establish a socket
      sleep 0.1

      # Try to kill immediately, this should fail
      Process.kill("TERM", current_echo_pid)

      # Make sure the term has time to arrive
      sleep 0.1

      expect(echo_server_running?).to be true

      # Should quit after the last process has disconnected
      connection_thread.join

      # Make sure the process has time to gracefully exit
      sleep 1

      expect(echo_server_running?).to be false
    end

    it "quits immediately after receiving a second TERM" do
      Thread.start do
        with_connection do |socket|
          sleep 1
        end
      end

      # Make sure the thread has had time to establish a socket
      sleep 0.1

      # First TERM waits for the connection to finish
      Process.kill("TERM", current_echo_pid)

      # Make sure the term has time to arrive
      sleep 0.1

      expect(echo_server_running?).to be true

      # Second TERN bails out immediately
      Process.kill("TERM", current_echo_pid)
      sleep 0.1 # immediately-ish
      expect(echo_server_running?).to be false
    end
  end

  context "on receiving USR1" do
    it 'spawns a new copy of the server' do
      original_pid = current_echo_pid
      Process.kill('USR1', original_pid)

      wait_for_pid_change

      expect(current_echo_pid).not_to eq(original_pid)
      expect(pid_running?(current_echo_pid)).to be true
    end

    it 'terminates the original server' do
      original_pid = current_echo_pid
      Process.kill('USR1', original_pid)

      wait_for_pid_change
      expect(pid_running?(original_pid)).to be false
    end

    it 'updates the pid file' do
      original_pid = current_echo_pid
      Process.kill('USR1', original_pid)

      wait_for_pid_change

      new_pid = File.read(echo_pid_path)
      expect(new_pid).not_to eq(original_pid)
    end
  end
end

# A functional test of an Uninterruptible::Server, see support/echo_server for server implementation
RSpec.describe "TcpServer" do
  include EchoServerControls

  before(:all) do
    start_server
  end

  after(:all) do
    stop_echo_server
  end

  it "starts a TCP server" do
    with_connection do |socket|
      expect(socket).to be_a(TCPSocket)
    end
  end

  it_behaves_like "an echo server"

  def start_server
    start_echo_server('tcp_server')
  end

  # Open a connection to the running echo server and yield the socket in the block. Autocloses once finished.
  def with_connection
    socket = TCPSocket.new("localhost", 6789)
    yield socket if block_given?
  ensure
    socket.close if socket
  end
end

RSpec.describe "UNIXServer", focus: true do
  include EchoServerControls

  before(:all) do
    start_server
  end

  after(:all) do
    stop_echo_server
  end

  it "starts a UNIX server" do
    with_connection do |socket|
      expect(socket).to be_a(UNIXSocket)
    end
  end

  it_behaves_like "an echo server"

  def start_server
    start_echo_server('unix_server')
  end

  # Open a connection to the running echo server and yield the socket in the block. Autocloses once finished.
  def with_connection
    socket = UNIXSocket.new('/tmp/echo_server.sock')
    yield socket if block_given?
  ensure
    socket.close if socket
  end
end

RSpec.describe "SSLServer" do
  include EchoServerControls

  before(:all) do
    start_server
  end

  after(:all) do
    stop_echo_server
  end

  it "starts a TLS server" do
    with_connection do |socket|
      expect(socket).to be_a(OpenSSL::SSL::SSLSocket)
    end
  end

  it_behaves_like "an echo server"

  def start_server
    start_echo_server('tls_server')
  end

  # Open a connection to the running echo server and yield the socket in the block. Autocloses once finished.
  def with_connection
    socket = TCPSocket.new("localhost", 6789)

    context = OpenSSL::SSL::SSLContext.new
    context.ssl_version = :TLSv1_2
    context.verify_mode = OpenSSL::SSL::VERIFY_NONE

    ssl_socket = OpenSSL::SSL::SSLSocket.new(socket, context)
    ssl_socket.connect

    yield ssl_socket if block_given?
  ensure
    ssl_socket.close if ssl_socket
    socket.close if socket
  end
end

def echo_server_running?
  pid_running?(current_echo_pid)
end

def pid_running?(pid)
  # Use waitpid to check on child processes, getpgid reports incorrectly for them
  Process.waitpid(pid, Process::WNOHANG).nil?
rescue Errno::ECHILD
  # Use Process.getpgid if it's not a child process we're looking for
  begin
    Process.getpgid(pid)
    true
  rescue Errno::ESRCH
    false
  end
end

# Wait for the echo server pidfile to change.
#
# @param [Integer] timeout Timeout in seconds
def wait_for_pid_change(timeout = 5)
  starting_pid = current_echo_pid
  timeout_tries = timeout * 2 # half second intervals

  tries = 0
  while current_echo_pid == starting_pid && tries < timeout_tries
    tries += 1
    sleep 0.5
  end

  raise "Timeout waiting for PID change" if timeout_tries == tries
end
