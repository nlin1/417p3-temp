require 'socket'
require 'csv'
require 'set'
require 'thread'

Thread.abort_on_exception = true

$shutdown_flag = false
$port = nil
$hostname = nil
$peers = {}
$LStable = Hash.new
$task_queue = Queue.new
$queue_semaphore = Mutex.new
$current_linkstate = 0

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
    "CIRCUIT" => :circuit,
    "LINKSTATE" => :linkstate
}

#dst -> nexthop, dist
$routing_table = Hash.new

class Peer

	attr_accessor :hostname
	attr_accessor :sock
	attr_accessor :buffer

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

#STRUCTURE OF LINKSTATE PACKET
#LINKSTATE, LSnum, SENDER NODE, AGE, PEER1, COST1, PEER2, COST2, etc.
def linkstate(msg)
	temp = []
	if msg == nil
		$current_linkstate += 1
		packet = "LINKSTATE " + $current_linkstate + " " + $hostname + " 20 "
		# packet[0] = "LINKSTATE"
		# packet[1] = $current_linkstate
		# packet[2] = $hostname
		# packet[3] = "20"
	   	$peers.each do |node, peer|
	   		packet += peer.hostname + " " + $routing_table[peer.hostname][1] + " "
	   	end
	else
		packet = msg
		temp = msg.split(' ')
		if !$LStable.has_key[temp[1]]
			$LStable[temp[1]] = Hash.new
		end

		if $LStable[temp[1]].has_key?(temp[2]) #if we have the packet already
			return;
		else	#otherwise keep packet
			$LStable[temp[1]][temp[2]] = temp[3..-1] #list of nodes and
		end
	end
   	$peers.each do |node, peer|
   		if(msg != nil && temp[2] != peer.hostname) #send to peers besides sender
   			peer.sock.puts(packet)
   		end
   	end
   	$current_linkstate += 1
end

def dijkstra(table)
  localhost = Peer.new("127.0.0.1", @hostname, nil)
  dist = Hash.new
  visited = Set.new
  nextNode = Queue.new
  dist[localhost] = 0
  parent = Hash.new
  $routing_table.each do |dest, val|
    dist[dest] = -1
  end
  while !nextNode.empty?
    nextHop = minDist(dist, nextNode)
    if visited.contains? nextHop
      next
    else
      visited.add(nextHop)
      nextHopName = nextHop.hostname
      neighborsList = table[nextHopName]
      neighbors = Hash.new
      for i in (0...neighborsList.length).step(2)
        neighbors[neighborsList[i]] = neighborsList[i + 1]
      end
      neighbors.each do |n|
        name = getNodeFromName(n)
        nextNode.add(name)
        distuTov = neighbors[n]
        if dist[name] > dist[nextHop] + distuTov || dist[name] == -1
          dist[name] = dist[nextHop] + distuTov
          parent[name] = nextHop
        end
      end
    end
  end
  $routing_table.each do |key, value|
    $routing_table[key] = [dist[key], getNextHop(parent, key)]
  end
end

def getNextHop(parent, node)
  if parent[parent[node]] == -1
    return node
  end
  getNextHop(parent, parent[node])
end

def getNodeFromName(hostname)
  res = nil
  $routing_table.each do |key, _|
    if key.hostname == hostname
      res = key
      break
    end
  end
  return res
end

def minDist(distTable, queue)
  min = nil
  val = nil
  queue.each do |item|
    if val == nil || distTable[item] < val
      val = distTable[item]
      min = item
    end
  end
  return min
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

		if temp[0] = "LINKSTATE"
			linkstate(line)

		temp[0] = $commands[temp[0]]

		$queue_semaphore.synchronize{
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
    task_clock = nil
    $clock_semaphore.synchronize {
        task_clock = $clock
    }
    runls = false
    while (true)
        time_flag = nil
        $clock_semaphore.synchronize {
            if (($clock - task_clock) >= $config_map["updateInterval"] * 2)
                time_flag = true
            else
                time_flag = false
            end
        }
        if time_flag
            # Do something for link state
            task_clock = $clock
            if runls
              linkstate(nil)
            else
              dijkstra($LStable)
            end
            runls = !runls
        else
            queue_flag = nil
            # Synchronize the thread using mutex
            $queue_semaphore.synchronize {
                # If there are tasks to do, execute them
                if (!task_queue.empty?)
                    task = task_queue.pop
                    cmd = task[1..-1]
                    queue_flag = true
                else
                    queue_flag = false
                end
            }
            # Use ruby's function sending to execute
            # the tasks that are enqueued
            if queue_flag
                if task[0] == :status
                    status()

                elsif task[0] == :edgeb
                	#puts "EDGEB Received"
					t_sock = TCPSocket.new cmd[0], cmd[2].to_i
					$peers[cmd[1]] = Peer.new(cmd[0], cmd[1], t_sock)
					$routing_table[cmd[1]] = [cmd[1], 1]
					STDOUT.flush

				elsif task[0] == :linkstate

                else
                    send(task[0], cmd)
                end
            end
        end
    end
end

setup(ARGV[0], ARGV[1], ARGV[2], ARGV[3])
