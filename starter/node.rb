require 'socket'
require 'csv'

Thread.abort_on_exception = true

$shutdown_flag = false
$port = nil
$hostname = nil
$socketToNode = {} #Hashmap to index node by socket
$nodeToSocket = {}
$peers = {}
$task_queue = Queue.new
queue_semaphore = Mutex.new

$commands = {
    "DUMPTABLE" => :dumptable,
    "SHUTDOWN" => :shutdown,
    "STATUS" => :status,
    "EDGEB" => :edgeb,
    "EDGEU" => :edgeu,
    "EDGED" => :edged,
    "SENDMSG" => :sendmsg,
    "PING" => :ping,
    "TRACEROUTE" => :traceroute,
    "FTP" => :ftp,
    "CIRCUIT" => :circuit
}

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

	def close_sock()
		sock.close
	end
end


# --------------------- Part 1 --------------------- #

=begin
 Format: EDGEB [SRCIP] [DSTIP] [DST]
 Description: This method creates a symmetric edge between the node on which the com-
mand is run, and the node specified by DST. By symmetric, we mean that the node specified
by DST should have the reverse edge in its routing table. The cost of the edge should be
initialized to 1. SRCIP and DSTIP are given to facilitate the initial connection between the
nodes. This will enable your edges to be build without the need for address resolution (as is
the case in NRL's CORE).
=end
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

=begin
 Format: DUMPTABLE [FILENAME]
 Description: When a node receives a DUMPTABLE command from the console, it should
write its current view of the routing table as a CSV (with NO headers) to the file specified
by FILENAME. The file should be created in the current working directory, and should be
created if it does not already exist. If the file already exists, it should be overwritten. The
file name will not include a leading \./"
=end
def dumptable(cmd)
	name = (cmd[0] =~ /\.\/*/) != nil ? cmd[0][2..-1] : cmd[0]
	if File.exist? name then
		File.delete(name)
	end
	File.new(name, "w")
	CSV.open(name, "w") do |csv|
		$routing_table.each { |k, v|
			csv << [$hostname, v[0], v[0], v[1]]
		}
	end
end

=begin
 Format: SHUTDOWN
 Description: This should cleanly shutdown the node and 
ush all pending write buffers (stdout, files, stderr). 
The node should exit with status 0.
=end
def shutdown(cmd)
	$shutdown_flag = true
	STDOUT.flush
	STDERR.flush
	exit(0)
end



# --------------------- Part 2 --------------------- #

=begin
 Format: EDGED [DST]
 Description: This method destroys the edge from the source node to the dst node (i.e.
removes all state information).
=end
def edged(cmd)
	$routing_table.delete(cmd[0])
	$peers[cmd[0]].close_sock
	$peers.delete(cmd[0])
end

=begin
 Format: EDGEU [DST] [COST]
 Description: This method updates the cost of the link from the current node to the neighbor
node specified by DST.
=end
def edgeu(cmd)
	if($routing_table.has_key(cmd[0]) && (cmd[1] >= -2147483648 && cmd[1] <= 2147483647))
		$routing_table[cmd[0]] = [$routing_table[cmd[0]][0], cmd[1]]
	end
end

=begin
 Format: STATUS
 Description:The node should print out the following status information, formatted as follows:
Name: <nodename>
Port: <port the node is listening on>
Neighbors: <lexicographically sorted list of neighbors, separated with commas and no spaces>
=end
def status()
	first = true
	print "Name: " + $hostname + "\nPort: " + $port + "\nNeighbors: "
	$routing_table.sort_by{|k,v| k}.each do |dst, nhop|
		if dst == nhop[0] #checks if node is direct neighbor
			if !first
				print ","
			else
				first = false
			end
			print dst
		end
	end
	print "\n"
	STDOUT.flush
end


# --------------------- Part 3 --------------------- #

=begin
 Format: SENDMSG [DST] [MSG]
 Description: This method will deliver the string MSG to the process running on DST.
=end
def sendmsg(cmd)
	STDOUT.puts "SENDMSG: not implemented"
end

=begin
 Format: PING [DST] [NUMPINGS] [DELAY]
 Description: This method will send NUMPINGS ping messages to the DST. There should
be a delay of DELAY seconds between pings.
=end
def ping(cmd)
	STDOUT.puts "PING: not implemented"
end

=begin
 Format: TRACEROUTE [DST]
 Description: This method will perform traceroute from the SRC to the DST.
=end
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
	$config_map = {}

	#set up ports, server, buffers

	File.open(nodes, mode = "r") do |file|
		file.each_line do |line|
			temp = line.split(',')
			$node_map[temp[0]] = temp[1]
		end
	end

	File.open(config, mode = "r") do |file|
		file.each_line do |line|
			temp = line.split('=')
			$config_map[temp[0]] = temp[1].to_i
		end
	end

	t1 = Thread.new {
		node_listener(port.to_i)
	}

	t2 = Thread.new{
		clock(config_map["updateInterval"])
	}

    t3 = Thread.new {
        task_thread()
    }

	main()
end

def node_listener(port)
	server = TCPServer.new port
	while $shutdown_flag == false do
		client = server.accept
		line = client.gets
		temp = line.split(" ")

		queue_semaphore.synchronize{
			$task_queue.push(temp)
		}

		# if temp[0] == "EDGEB"
		# 	#puts "EDGEB Received"
		# 	t_sock = TCPSocket.new temp[1], temp[3].to_i
		# 	$peers[temp[2]] = Peer.new(temp[1], temp[2], t_sock)
		# 	$routing_table[temp[2]] = [temp[2], 1]
		# 	STDOUT.flush
		# end

		client.close
	end
	server.close
end

def clock(update_interval)
	$sleep_interval =  update_interval / 2
	$clock_semaphore = Mutex.new
	$clock = Time.now
	while(true)
		sleep($sleep_interval)
		$clock_semaphore.synchronize{
			$clock = $clock + $sleep_interval
		}
	end
end

def task_thread()
    num_args = {

    }
    while (true)
        if (!task_queue.empty?)
            task = task_qeueu.pop

        end
    end
end

setup(ARGV[0], ARGV[1], ARGV[2], ARGV[3])
