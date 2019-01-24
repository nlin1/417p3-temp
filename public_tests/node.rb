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
$recentLSPacket = Hash.new
$task_queue = Array.new
$queue_semaphore = Mutex.new
$current_linkstate = 0
$pings = {}
$traceroutes = {}
$logfile = nil


$sendmsgBuffer = Hash.new


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
    "LINKSTATE" => :linkstate,
  "ROUTES" => :routes
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
	if msg == nil
		$current_linkstate += 1
		packet = "LINKSTATE " + $current_linkstate.to_s + " " + $hostname + " 20 "
		# packet[0] = "LINKSTATE"
		# packet[1] = $current_linkstate
		# packet[2] = $hostname
		# packet[3] = "20"
	   	$peers.each do |node, peer|
	   		packet = packet + peer.hostname + " " + $routing_table[peer.hostname][1].to_s + " "
	   	end
        temp = [nil, $current_linkstate]
	else
		packet = msg
		temp = msg.split(' ')
		if !$LStable.has_key?(temp[1])
			$LStable[temp[1]] = Hash.new
		end

		if $LStable[temp[1]].has_key?(temp[2]) #if we have the packet already
			log($logfile, "linkstate", "found pre-existing packet")
			return
		else	#otherwise keep packet
			$LStable[temp[1]][temp[2]] = temp[3..-1] #list of nodes and
            $recentLSPacket[temp[2]] = temp[4..-1]
            $current_linkstate = temp[0].to_i
		end
	end
  
   	$peers.each do |node, peer|

   		if(temp[2] != peer.hostname) #send to peers besides sender
   			log($logfile, "linkstate", "Attempting to write to " + node + " on sockfd " + peer.sock.to_s + " packet " + packet)
   			peer.sock.puts(packet)
            peer.sock.flush
   		end
   	end
   	$current_linkstate = temp[1].to_i
   	packet.clear
end

def dijkstra(tbl)
  table = tbl
  localhost = Peer.new("127.0.0.1", @hostname, nil)
  dist = Hash.new
  visited = Set.new
  nextNode = Queue.new
  dist[@hostname] = 0
  parent = Hash.new
  parent[@hostname] = -1
  $routing_table.each do |dest, val|
    dist[dest] = -1
  end
  $peers.each do |key, val|
    nextNode.push(key)
    dist[key] = $routing_table[key][1]
    #log($logfile, "dijkstra", "dist[key]=" + $routing_table[key][1].to_s)
    parent[key] = @hostname
  end
  message = "Next Nodes - " + nextNode.size.to_s
  #log($logfile, "dijkstra", message)
  while !nextNode.empty?
    nextHop = nextNode.pop
    #nextHop = minDist(dist, nextNode)
    if visited.member? nextHop 
      next
    else
      visited.add(nextHop)
      nextHopName = nextHop
      neighborsList = table[nextHopName]
      if neighborsList == nil
        neighborsList = []
      end
      neighbors = Hash.new
      for i in (0...neighborsList.length).step(2)
        #log($logfile, "dijkstra", "neighborsList[i + 1]=" + neighborsList[i + 1])
        neighbors[neighborsList[i]] = neighborsList[i + 1].to_i
        if !dist.key? neighborsList[i]
          dist[neighborsList[i]] = -1
        end
      end
      neighbors.each do |n, v|
        nextNode.push(n)
        distuTov = v
        #log($logfile, "dijkstra", "dist[nextHop]->" + dist[nextHop].class.to_s)
        #log($logfile, "dijkstra", "distuTov->" + distuTov.class.to_s)
        if dist[n] > dist[nextHop] + distuTov || dist[n] == -1
          dist[n] = dist[nextHop] + distuTov
          parent[n] = nextHop
        end
        #puts "wjat"
      end
    end
  end
  #log($logfile, "dijkstra", dist.to_s)
  dist.each do |key, value|
    unless key.nil? || key == $hostname
      $routing_table[key] = [getNextHop(parent, key), dist[key]]
    end
  end
  log($logfile, "dijkstra", $routing_table.to_s)
end

def getNextHop(parent, node)
  if parent[parent[node]] == -1 || parent[node] == -1
    return node
  end
  getNextHop(parent, parent[node])
end

def getNodeFromName(hostname)
  res = nil
  $routing_table.each do |key, _|
    if key == hostname
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

def routes(cmd)
  $routing_table.each do |key, value|
    STDOUT.print key + ", "
  end
  STDOUT.puts ""
  STDOUT.flush
end

def log(logFile, functionName, message)
  time = nil
  $clock_semaphore.synchronize {
    time = $clock
  }
  message = functionName + " " + time.to_s + ": " + message + "\n"
  if !File.exists? logFile
    File.new(logFile, "a+")
  end
  File.open(logFile, "a+") do |file|
    file << message
  end
end


#sendmsg fragmentation helpers
def isFragment? msg
  return msg.length == 5
end

def addToBuffer(msg)
  src = msg[1]
  message = msg[2]
  id = msg[3].to_i
  maxNum = msg[4].to_i
  if !$sendmsgBuffer.key? src
    $sendmsgBuffer[src] = Hash.new
    $sendmsgBuffer[src]["max"] = maxNum
    $sendmsgBuffer[src][id] = message
  else
    $sendmsgBuffer[src][id] = message
  end
  # Return true is all fragments have been received, else return false
  res = $sendmsgBuffer[src].length == $sendmsgBuffer[src]["max"] + 1
  return res
end

def retMsg(src, maxNum)
  buffer = src + " --> "
  for i in 0...maxNum
    buffer = buffer + $sendmsgBuffer[src][i].tr('_', ' ')
  end
  return buffer
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
	#puts "in main edgeb"
	if($routing_table.has_key?(cmd[2]) && $routing_table[cmd[2]][1] == 1)
		return nil
	else
		$routing_table[cmd[2]] = [cmd[2], 1]
	end
	sock = TCPSocket.new cmd[1], $node_map[cmd[2]].to_i
	sock.sync = true
	$peers[cmd[2]] = Peer.new(cmd[1], cmd[2], sock)
	#puts "Sockfd: " + sock.to_s + " connected to peer " + cmd[2].to_s
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
	if($routing_table.has_key?(cmd[0]) && (cmd[1].to_i >= -2147483648 && cmd[1].to_i <= 2147483647))
		$routing_table[cmd[0]] = [$routing_table[cmd[0]][0], cmd[1].to_i]
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
=begin
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
=end
  $peers.each do |peer, _|
    if !first
      print ","
    else
      first = false
    end
    print peer
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
	if $routing_table.has_key?(cmd[0])
	  concat = cmd[1..-1].join("_")
          if concat.length > $config_map["maxPayload"].to_i
            # If message is larger than payload, split it into fragments
            fragments = Array.new
            start = 0
            finish = concat.length
            # Reserve 3 bytes for counter and last fragment info
            payload = $config_map["maxPayload"].to_i - 3 
            counter = 0
            while start < finish
              if start + payload > finish
                msg = "SENDMSG " + cmd[0] + " " + $hostname + " " + concat[start..-1] + " " + counter.to_s
              else
                msg = "SENDMSG " + cmd[0] + " " + $hostname + " " + concat[start...(start + payload)] + " " + counter.to_s
              end
              fragments.push(msg)
              counter += 1
              start = start + payload
            end
            fragments.each do |msg|
              $peers[$routing_table[cmd[0]][0]].sock.puts msg + " " + fragments.length.to_s
              $peers[$routing_table[cmd[0]][0]].sock.flush
            end
          else
	    	$peers[$routing_table[cmd[0]][0]].sock.puts "SENDMSG " + cmd[0] + " " + $hostname + " " + concat
	    	$peers[$routing_table[cmd[0]][0]].sock.flush
          end
	else
		STDOUT.puts "SENDMSG ERROR: HOST UNREACHABLE - main"
		STDOUT.flush
	end
end

=begin
 Format: PING [DST] [NUMPINGS] [DELAY]
 Description: This method will send NUMPINGS ping messages to the DST. There should
be a delay of DELAY seconds between pings.
=end
def ping(cmd)
	if not $routing_table.has_key?(cmd[0])
		STDOUT.puts "PING ERROR: HOST UNREACHABLE"
		return
	end
	$pings.clear
	ping_no = 0
	#puts "ping " + cmd[1] + "."
	thr = Thread.new{
		while ping_no < cmd[1].to_i
			#cmd: dst, sender, seq id, returning flag, ping num
			#puts "Attempting to write PING " + cmd[0] + " " + $hostname + " " + ping_no.to_s + " false "
			$peers[$routing_table[cmd[0]][0]].sock.puts "PING " + cmd[0] + " " + $hostname + " " + ping_no.to_s + " false "
			$pings[ping_no] = [Time.now, false]
			ping_no += 1
			sleep(cmd[2].to_i)
			i = 0
			while i < ping_no
				if $pings[i][1] == false && $clock - $pings[i][0] >= $config_map["pingTimeout"].to_i
					STDOUT.puts "PING ERROR: HOST UNREACHABLE"
					$pings[i][1] = true
				end
				i += 1
			end
		end
	}
	thr.join
	ping_no = 0
end

=begin
 Format: TRACEROUTE [DST]
 Description: This method will perform traceroute from the SRC to the DST.
=end
def traceroute(cmd)
	$tr = []
	$tr.push(0)
	$max_hop = 0
	if not $routing_table.has_key?(cmd[0])
		STDOUT.puts "TIMEOUT ON 0"
		return
	end
	$peers[$routing_table[cmd[0]][0]].sock.puts "TRACEROUTE " + cmd[0] + " 1 false " + Time.now.to_f.to_s + " " + $hostname
	STDOUT.puts "0 " + $hostname + " 0"

	thr = Thread.new{
		sleep($config_map["pingTimeout"].to_i)
		for i in 0..($max_hop)
			if not $tr.include?(i)
				STDOUT.puts "TIMEOUT ON " + i.to_s
			end
		end
	}
	thr.join
	#cmd: dst, hop, returning flag, time sent, sender
	$tr.clear
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
		when "EDGEU"; edgeu(args)
		when "DUMPTABLE"; dumptable(args) #part 0
		when "SHUTDOWN"; shutdown(args)	#part0
		when "STATUS"; status()
		when "SENDMSG"; sendmsg(args)
		when "PING"; ping(args)
		when "TRACEROUTE"; traceroute(args)
		when "FTP"; ftp(args);
		when "CIRCUIT"; circuit(args);
        when "ROUTES"; routes(args);
		else STDERR.puts "ERROR: INVALID COMMAND \"#{cmd}\""
		end
	end

end

def setup(hostname, port, nodes, config)
	$hostname = hostname
	$port = port
	$node_map = {}
	$config_map = {}
	$clock_semaphore = Mutex.new
	$clock = Time.now
  	$logfile = "log" + $hostname + ".txt"

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
		clock($config_map["updateInterval"])
	}

    t3 = Thread.new {
        task_thread()
    }

	main()
end

def node_listener(port)
	i = 0
	server = TCPServer.new port
  	#rp, wp = IO.pipe

  	loop do

	  	Thread.start(server.accept) do |client|
	    
			while $shutdown_flag == false do

				#puts "Server " + $hostname + " connected to " + client.to_s 
	              
				line = client.gets
				temp = line.split(" ")

				#puts "" + $hostname + " recieved packet, count = " + i.to_s + " // " + line

				log($logfile, "node_listener", "" + $hostname + " recieved packet, count = " + i.to_s + " // " + line)
				i += 1

				if temp[0] == "LINKSTATE"
		            $queue_semaphore.synchronize {
						linkstate(line)
		            }
				else
					#puts temp[0] + " " + $commands[temp[0]].to_s

					temp[0] = $commands[temp[0]]
					$queue_semaphore.synchronize{
						$task_queue.push(line)
					}
				end

			end

	            # rescue
	            #   rs, ws = IO.select([rp], [wp])
	            #   rs.each do |sock|
	            #     line = sock.gets
	            #     temp = line.split(" ")
	            #     if temp[0] == "LINKSTATE"
	            #       $queue_semaphore.synchronize {
	            #         linkstate(line)
	            #       }
	            #     else
	            #       puts temp[0] + " " + $commands[temp[0]].to_s
	            #       temp[0] = $commands[temp[0]]
	            #       $queue_semaphore.synchronize {
	            #         $task_queue.push(temp)
	            #       }
	            #   end
	            # end
	            # end

			# if temp[0] == "EDGEB"
			# 	#puts "EDGEB Received"
			# 	t_sock = TCPSocket.new temp[1], temp[3].to_i
			# 	$peers[temp[2]] = Peer.new(temp[1], temp[2], t_sock)
			# 	$routing_table[temp[2]] = [temp[2], 1]
			# 	STDOUT.flush
			# end

			#client.close
		end
	end
	server.close
end

def clock(update_interval)
	$sleep_interval =  update_interval
	while(true)
		sleep($sleep_interval)
		$clock_semaphore.synchronize{
			$clock = $clock + $sleep_interval
		}
		#puts "clock incremented to " + $clock.to_s
		#puts "queue: " + ($task_queue.first == nil ? "nil" : $task_queue.first.to_s)

	end
end

def task_thread()
	#puts "task thread started"
    task_clock = nil
    temp = ""
    task = []
    cmd = []
    $clock_semaphore.synchronize {
        task_clock = $clock
    }
    runls = true
    while (true)
        time_flag = nil
        $clock_semaphore.synchronize {
            if (($clock - task_clock) >= $config_map["updateInterval"]*2)
                time_flag = true
                task_clock = $clock
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
              dijkstra($recentLSPacket)
            end
            runls = !runls
        else
            queue_flag = nil
            # Synchronize the thread using mutex
            $queue_semaphore.synchronize {
                # If there are tasks to do, execute them
                if ($task_queue.first != nil)
                	#puts "found item in task queue"
                    temp = $task_queue.shift
                    task = temp.split(" ")
                    cmd = task[1..-1]
                    queue_flag = true
                    task[0] = $commands[task[0]]
                else
                    queue_flag = false
                end
            }
            # Use ruby's function sending to execute
            # the tasks that are enqueued
            if queue_flag
                if task[0] == :edgeb
                	#puts "EDGEB Received, in task thread"
					t_sock = TCPSocket.new cmd[0], cmd[2].to_i
					t_sock.sync = true
					$peers[cmd[1]] = Peer.new(cmd[0], cmd[1], t_sock)
					#puts "Sockfd: " + t_sock.to_s + " connected to peer " + cmd[1].to_s
					$routing_table[cmd[1]] = [cmd[1], 1]

				#cmd: dst, sender, msg
				elsif task[0] == :sendmsg
					if cmd[0] == "fail" && cmd[1] == $hostname
						STDOUT.puts "SENDMSG ERROR: HOST UNREACHABLE - task"
						STDOUT.flush
					elsif cmd[0] == $hostname #INTENDED BEHAVIOR
                      if isFragment? cmd
                        add = addToBuffer(cmd)
                        if add
                          STDOUT.puts retMsg(cmd[1], cmd[4].to_i)
                          STDOUT.flush
                        end
                        log($logfile, "sendmsg", "fragmented message received")
                      else
    					STDOUT.puts cmd[1] + " --> " + cmd[2].tr('_',' ')
    					STDOUT.flush
                      end
					elsif not $routing_table.has_key?(cmd[0])
						$peers[$routing_table[cmd[1]][0]].sock.puts "SENDMSG fail " + cmd[1] + " *"
						$peers[$routing_table[cmd[1]][0]].sock.flush
					else
                      if isFragment? cmd
                        $peers[$routing_table[cmd[0]][0]].sock.puts "SENDMSG " + cmd[0] + " " + cmd[1] + " " + cmd[2] + " " + cmd[3] + " " + cmd[4]
                        $peers[$routing_table[cmd[0]][0]].sock.flush
                      else
    					$peers[$routing_table[cmd[0]][0]].sock.puts "SENDMSG " + cmd[0] + " " + cmd[1] + " " + cmd[2]
    					$peers[$routing_table[cmd[0]][0]].sock.flush
                  	  end
					end

				#cmd: dst, sender, seq num, returning flag
				elsif task[0] == :ping
					if cmd[0] == "fail" && cmd[1] == $hostname
						STDOUT.puts "PING ERROR: HOST UNREACHABLE"
					elsif cmd[0] == $hostname && cmd[3] == "true" #INTENDED BEHAVIOR
						if $pings[cmd[2].to_i][1] == false
							STDOUT.puts cmd[2] + " " + cmd[1] + " " + (Time.now - $pings[cmd[2].to_i][0]).to_s
							$pings[cmd[2].to_i][1] = true
						end
					elsif cmd[0] == $hostname && cmd[3] == "false"
						$peers[$routing_table[cmd[1]][0]].sock.puts "PING " + cmd[1] + " " + $hostname + " " + cmd[2] + " true "
					elsif not $routing_table.has_key?(cmd[0])
						$peers[$routing_table[cmd[1]][0]].sock.puts "PING fail " + cmd[1] + " * *"
					elsif cmd[0] != $hostname
						$peers[$routing_table[cmd[0]][0]].sock.puts "PING " + cmd[0] + " " + cmd[1] + " " + cmd[2] + " " + cmd[3]
					end

				#cmd: dst, hop, returning flag, time sent, sender
				elsif task[0] == :traceroute
					if cmd[0] == $hostname && cmd[3] == "fail"
						STDOUT.puts "TIMEOUT on " + cmd[3]
					elsif cmd[0] == $hostname && cmd[2] == "false"
						$peers[$routing_table[cmd[4]][0]].sock.puts "TRACEROUTE " + cmd[4] + " " + cmd[1] + " true " + (Time.now.to_f - cmd[3].to_f).to_s + " " + $hostname
					elsif cmd[0] == $hostname && cmd[2] == "true"
						$tr.push(cmd[1].to_i)
						if cmd[1].to_i > $max_hop
							$max_hop = cmd[1].to_i
						end
						STDOUT.puts cmd[1] + " " + cmd[4] + " " + cmd[3]
					elsif not $routing_table.has_key?(cmd[0])
						$peers[$routing_table[cmd[4]][0]].sock.puts "TRACEROUTE " + cmd[4] + (cmd[1].to_i + 1).to_s + " true fail *"  
					elsif cmd[0] != $hostname && cmd[2] == "false"
						$peers[$routing_table[cmd[0]][0]].sock.puts "TRACEROUTE " + cmd[0] + " " + (cmd[1].to_i + 1).to_s + " " + cmd[2] + " " + cmd[3] + " " + cmd[4]
						$peers[$routing_table[cmd[4]][0]].sock.puts "TRACEROUTE " + cmd[4] + " " + cmd[1] + " true " + (Time.now.to_f - cmd[3].to_f).to_s + " " + $hostname
					elsif cmd[0] != $hostname && cmd[2] == "true"
						$peers[$routing_table[cmd[0]][0]].sock.puts "TRACEROUTE " + cmd[0] + " " + cmd[1] + " true " + cmd[3] + " " + cmd[4]
					end
                #elsif (task != nil)
                #    send($commands[task[0]], cmd)
                end

                task.clear
                #cmd.clear
                temp = ""
            end
        end
    end
end


setup(ARGV[0], ARGV[1], ARGV[2], ARGV[3])
