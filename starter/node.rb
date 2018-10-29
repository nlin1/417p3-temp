require 'socket'
require 'csv'


$shutdown_flag = false
$port = nil
$hostname = nil
$socketToNode = {} #Hashmap to index node by socket
$nodeToSocket = {}
$peers = {}

#dst -> nexthop, dist
$routing_table = Hash.new

class Peer
	def initialize(ip, name, sock)
		@buffer = ""
		@ip = ip;
		@hostname = name
		@seq_num = 0
		@sock = sock
	end


end


# --------------------- Part 1 --------------------- #

def edgeb(cmd)
	if($routing_table.has_key?(cmd[2]) && $routing_table[cmd[2]][1] == 1)
		return nil
	else
		$routing_table[cmd[2]] = [cmd[2], 1]
	end
	sock = TCPSocket.new cmd[1], $node_map[cmd[2]].to_i
	$peers[cmd[2]] = Peer.new(cmd[1], cmd[2], sock)
	sock.puts "EDGEB " + cmd[0] + " " + $hostname + " " + $port
	return 0
end

def dumptable(cmd)
	f = nil
	name = (cmd[0] =~ /\.\/*/) != nil ? cmd[0][2..-1] : cmd[0]
	if File.exist? name then
		g = File.open(name, "w")
		g.truncate(0)
	else
		File.new(name, "w")
	end
	CSV.open(name) do |csv|
		$routing_table.each { |k, v|
			csv << [hostname, k, v[0], v[1]]
		}
		csv.close
	end
end

def shutdown(cmd)
	shutdown_flag = true
	STDOUT.flush
	STDERR.flush
	exit(0)
end



# --------------------- Part 2 --------------------- #
def edged(cmd)
	STDOUT.puts "EDGED: not implemented"
end

def edgeu(cmd)
	STDOUT.puts "EDGEu: not implemented"
end

def status()
	STDOUT.puts "STATUS: not implemented"
end


# --------------------- Part 3 --------------------- #
def sendmsg(cmd)
	STDOUT.puts "SENDMSG: not implemented"
end

def ping(cmd)
	STDOUT.puts "PING: not implemented"
end

def traceroute(cmd)
	STDOUT.puts "TRACEROUTE: not implemented"
end

# --------------------- Part 4 --------------------- #


def ftp(cmd)
	STDOUT.puts "FTP: not implemented"
end

def circuit(cmd)
	STDOUT.puts "CIRCUIT: not implemented"
end




# do main loop here....
def main()

	while(line = STDIN.gets())
		line = line.strip()
		arr = line.split(' ')
		cmd = arr[0]
		args = arr[1..-1]
		case cmd
		when "EDGEB"; edgeb(args) #part 0
		when "EDGED"; edged(args)
		when "EDGEU"; edgeU(args)
		when "DUMPTABLE"; dumptable(args) #part 0
		when "SHUTDOWN"; shutdown(args)	#part0
		when "STATUS"; status()
		when "SENDMSG"; sendmsg(args)
		when "PING"; ping(args)
		when "TRACEROUTE"; traceroute(args)
		when "FTP"; ftp(args);
		when "CIRCUIT"; circuit(args);
		else STDERR.puts "ERROR: INVALID COMMAND \"#{cmd}\""
		end
	end

end

def setup(hostname, port, nodes, config)
	$hostname = hostname
	$port = port
	$node_map = {}

	#set up ports, server, buffers

	File.open(nodes, mode = "r") do |file|
		file.each_line do |line|
			temp = line.split(',')
			$node_map[temp[0]] = temp[1]
		end
	end

	t = Thread.new {
		node_listener(port.to_i)
	}

	main()

end

def node_listener(port)
	server = TCPServer.new port
	while $shutdown_flag == false do
		client = server.accept
		line = client.gets
		temp = line.split(" ")
		if temp[0] == "EDGEB"
			puts "EDGEB Received"
			t_sock = TCPSocket.new temp[1], temp[3].to_i
			$peers[temp[2]] = Peer.new(temp[1], temp[2], t_sock)
			$routing_table[temp[1]] = [temp[1], 1]
			STDOUT.flush
		end
		client.close
	end
	server.close
end


setup(ARGV[0], ARGV[1], ARGV[2], ARGV[3])
