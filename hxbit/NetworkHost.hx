/*
 * Copyright (C)2015-2016 Nicolas Cannasse
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
package hxbit;
import hxbit.NetworkSerializable.NetworkSerializer;

class NetworkClient {

	var host : NetworkHost;
	var resultID : Int;
	var needAlive : Bool;
	var wasSync : Bool;
	public var seqID : Int;
	public var ownerObject : NetworkSerializable;
	public var lastMessage : Float;

	public function new(h) {
		this.host = h;
		lastMessage = haxe.Timer.stamp();
	}

	public function sync() {
		host.fullSync(this);
	}

	@:allow(hxbit.NetworkHost)
	function send(bytes : haxe.io.Bytes) {
	}

	public function sendMessage( msg : Dynamic ) {
		if( host != null ) host.sendMessage(msg, this);
	}

	function error( msg : String ) {
		throw msg;
	}

	function processMessage( bytes : haxe.io.Bytes, pos : Int ) {
		var ctx = host.ctx;
		ctx.setInput(bytes, pos);
		ctx.errorPropId = -1;

		if( ctx.error )
			host.logError("Unhandled previous error");

		var mid = ctx.getByte();

		if( needAlive && mid != NetworkHost.REG ) {
			needAlive = false;
			host.makeAlive();
		}

		if( !wasSync && !host.isAuth ) {
			switch( mid ) {
			case NetworkHost.FULLSYNC, NetworkHost.MSG, NetworkHost.BMSG, NetworkHost.CUSTOM, NetworkHost.BCUSTOM:
			default:
				host.logError("Message "+mid+" was received before sync");
			}
		}

		switch( mid ) {
		case NetworkHost.SYNC:
			var oid = ctx.getInt();
			var o : hxbit.NetworkSerializable = cast ctx.refs[oid];
			if( o == null ) {
				host.logError("Could not sync object", oid);
				return -1; // discard whole data, might skip some other things
			}
			var rawBits = ctx.getInt();
			var bits1, bits2;
			switch( rawBits >>> 30 ) {
			case 0:
				bits1 = rawBits;
				bits2 = 0;
			case 1:
				bits1 = rawBits & 0x3FFFFFFF;
				bits2 = ctx.getInt();
			default: // 2,3
				bits1 = 0;
				bits2 = rawBits & 0x7FFFFFFF;
			}
			if( host.isAuth ) {
				inline function checkBits( b, offs ) {
					while( b != 0 ) {
						var bit = switch( b & -b ) {
						case 0x1: 0;
						case 0x2: 1;
						case 0x4: 2;
						case 0x8: 3;
						case 0x10: 4;
						case 0x20: 5;
						case 0x40: 6;
						case 0x80: 7;
						case 0x100: 8;
						case 0x200: 9;
						case 0x400: 10;
						case 0x800: 11;
						case 0x1000: 12;
						case 0x2000: 13;
						case 0x4000: 14;
						case 0x8000: 15;
						default: throw "assert";
						}
						offs += bit;
						if( !o.networkAllow(SetField, offs, ownerObject) ) {
							host.logError("Client setting unallowed property " + o.networkGetName(offs) + " on " + o, o.__uid);
							break;
						}
						offs++;
						b >>>= bit + 1;
					}
					return b == 0;
				}
				if( !checkBits(bits1&0xFFFF,0) || !checkBits(bits1>>>16,16) || !checkBits(bits2&0xFFFF,30) || !checkBits(bits2>>>16,46) )
					return -1;
			}
			if( host.logger != null ) {
				var props = [];
				inline function logProps(bits: Int, offset: Int) {
					var i = 0;
					while( 1 << i <= bits ) {
						if( bits & (1 << i) != 0 )
							props.push(o.networkGetName(i + offset));
						i++;
					}
				}
				logProps(bits1, 0);
				logProps(bits2, 30);
				host.logger("SYNC < " + o + "#" + o.__uid + " " + props.join("|"));
			}
			var old1 = o.__bits1, old2 = o.__bits2;
			o.__bits1 = bits1;
			o.__bits2 = bits2;
			host.syncingProperties = true;
			o.networkSync(ctx);
			host.syncingProperties = false;
			if( host.isAuth && (o.__next != null || host.mark(o)) ) {
				o.__bits1 = old1 | bits1;
				o.__bits2 = old2 | bits2;
			} else {
				o.__bits1 = old1 & (~bits1);
				o.__bits2 = old2 & (~bits2);
			}
			if( ctx.error )
				host.logError("Found unreferenced object while syncing " + o + "." + o.networkGetName(ctx.errorPropId));
		case NetworkHost.REG:
			var o : hxbit.NetworkSerializable = cast ctx.getAnyRef();
			if( ctx.error )
				host.logError("Found unreferenced object while registering " + o + "." + o.networkGetName(ctx.errorPropId));
			needAlive = true;
		case NetworkHost.UNREG:
			var oid = ctx.getInt();
			var o : hxbit.NetworkSerializable = cast ctx.refs[oid];
			if( o == null ) {
				host.logError("Could not unregister object", oid);
			} else {
				o.__host = null;
				ctx.refs.remove(o.__uid);
				host.onUnregister(o);
			}
		case NetworkHost.FULLSYNC:
			wasSync = true;
			ctx.refs = new Map();
			@:privateAccess {
				hxbit.Serializer.UID = 0;
				hxbit.Serializer.SEQ = ctx.getByte();
				ctx.newObjects = [];
			};
			var sign = ctx.getBytes();
			if( sign.compare(Serializer.getSignature()) != 0 )
				host.logError("Network signature mismatch");
			ctx.enableChecks = false;
			while( true ) {
				var o = ctx.getAnyRef();
				if( o == null ) break;
			}
			ctx.enableChecks = true;
			host.makeAlive();
		case NetworkHost.RPC:
			var oid = ctx.getInt();
			var o : hxbit.NetworkSerializable = cast ctx.refs[oid];
			var size = ctx.getInt32();
			var fid = ctx.getByte();
			if( o == null ) {
				if( size < 0 )
					throw "RPC on unreferenced object cannot be skip on this platform";
				if( !host.isAuth )
					host.logError("RPC @" + fid + " on unreferenced object", oid);
				ctx.skip(size);
			} else if( !host.isAuth ) {
				if( !o.networkRPC(ctx, fid, this) )
					host.logError("RPC @" + fid + " on " + o + " has unreferenced object parameter");
			} else {
				host.rpcClientValue = this;
				o.networkRPC(ctx, fid, this); // ignore result (client made an RPC on since-then removed object - it has been canceled)
				host.rpcClientValue = null;
			}
			if(host.logger != null) {
				host.logger("RPC < " + o+"#"+o.__uid + " " + o.networkGetName(fid,true));
			}
		case NetworkHost.RPC_WITH_RESULT:

			var old = resultID;
			resultID = ctx.getInt();
			var oid = ctx.getInt();
			var o : hxbit.NetworkSerializable = cast ctx.refs[oid];
			var size = ctx.getInt32();
			var fid = ctx.getByte();
			if( o == null ) {
				if( size < 0 )
					throw "RPC on unreferenced object cannot be skip on this platform";
				if( !host.isAuth )
					host.logError("RPC @" + fid + " on unreferenced object", oid);
				ctx.skip(size);
				ctx.addByte(NetworkHost.CANCEL_RPC);
				ctx.addInt(resultID);
			} else if( !host.isAuth ) {
				if( !o.networkRPC(ctx, fid, this) ) {
					host.logError("RPC @" + fid + " on " + o + " has unreferenced object parameter");
					ctx.addByte(NetworkHost.CANCEL_RPC);
					ctx.addInt(resultID);
				}
			} else {
				host.rpcClientValue = this;
				if( !o.networkRPC(ctx, fid, this) ) {
					ctx.addByte(NetworkHost.CANCEL_RPC);
					ctx.addInt(resultID);
				}
				host.rpcClientValue = null;
			}

			if( host.checkEOM ) ctx.addByte(NetworkHost.EOM);

			host.doSend();
			host.targetClient = null;
			resultID = old;

		case NetworkHost.RPC_RESULT:

			var resultID = ctx.getInt();
			var callb = host.rpcWaits.get(resultID);
			host.rpcWaits.remove(resultID);
			callb(ctx);

		case NetworkHost.CANCEL_RPC:

			var resultID = ctx.getInt();
			host.rpcWaits.remove(resultID);

		case NetworkHost.MSG:
			var msg = haxe.Unserializer.run(ctx.getString());
			host.onMessage(this, msg);

		case NetworkHost.BMSG:
			var msg = ctx.getBytes();
			host.onMessage(this, msg);

		case NetworkHost.CUSTOM:
			host.onCustom(this, ctx.getInt(), null);

		case NetworkHost.BCUSTOM:
			var id = ctx.getInt();
			host.onCustom(this, id, ctx.getBytes());

		case x:
			error("Unknown message code " + x+" @"+pos+":"+bytes.toHex());
		}
		return @:privateAccess ctx.inPos;
	}

	function beginRPCResult() {
		host.flush();

		if( host.logger != null )
			host.logger("RPC RESULT #" + resultID);

		var ctx = host.ctx;
		host.targetClient = this;
		ctx.addByte(NetworkHost.RPC_RESULT);
		ctx.addInt(resultID);
		// after that RPC will add result value then return
	}

	var pendingBuffer : haxe.io.Bytes;
	var pendingPos : Int;
	var messageLength : Int = -1;

	function readData( input : haxe.io.Input, available : Int ) {
		if( messageLength < 0 ) {
			if( available < 4 )
				return false;
			messageLength = input.readInt32();
			if( pendingBuffer == null || pendingBuffer.length < messageLength )
				pendingBuffer = haxe.io.Bytes.alloc(messageLength);
			pendingPos = 0;
		}
		var len = input.readBytes(pendingBuffer, pendingPos, messageLength - pendingPos);
		pendingPos += len;
		if( pendingPos == messageLength ) {
			processMessagesData(pendingBuffer, 0, messageLength);
			messageLength = -1;
			return true;
		}
		return false;
	}

	function processMessagesData( data : haxe.io.Bytes, pos : Int, length : Int ) {
		if( length > 0 )
			lastMessage = haxe.Timer.stamp();
		var end = pos + length;
		while( pos < end ) {
			var oldPos = pos;
			pos = processMessage(data, pos);
			if( pos < 0 )
				break;
			if( host.checkEOM ) {
				if( data.get(pos) != NetworkHost.EOM ) {
					var len = end - oldPos;
					if( len > 128 ) len = 128;
					throw "Message missing EOM @"+(pos - oldPos)+":"+data.sub(oldPos, len).toHex();
				}
				pos++;
			}
		}
		if( needAlive ) {
			needAlive = false;
			host.makeAlive();
		}
	}

	public function stop() {
		if( host == null ) return;
		host.clients.remove(this);
		host.pendingClients.remove(this);
		host = null;
	}

}

@:allow(hxbit.NetworkClient)
class NetworkHost {

	static inline var SYNC 		= 1;
	static inline var REG 		= 2;
	static inline var UNREG 	= 3;
	static inline var FULLSYNC 	= 4;
	static inline var RPC 		= 5;
	static inline var RPC_WITH_RESULT = 6;
	static inline var RPC_RESULT = 7;
	static inline var MSG		 = 8;
	static inline var BMSG		 = 9;
	static inline var CUSTOM	 = 10;
	static inline var BCUSTOM	 = 11;
	static inline var CANCEL_RPC = 12;
	static inline var EOM		 = 0xFF;

	public static var CLIENT_TIMEOUT = 60. * 60.; // 1 hour timeout

	public var checkEOM(get, never) : Bool;
	inline function get_checkEOM() return true;

	public static var current : NetworkHost = null;

	public var isAuth(default, null) : Bool;

	/**
		When a RPC of type Server is performed, this will tell the originating client from the RPC.
	**/
	public var rpcClient(get, never) : NetworkClient;

	public var sendRate : Float = 0.;
	public var totalSentBytes : Int = 0;
	public var syncingProperties = false;

	/*
		In order to allow detection of setting other properties within prop sync,
		we need to test the difference within the setter.
	*/
	var isSyncingProperty : Int = -1;

	var perPacketBytes = 20; // IP + UDP headers
	var lastSentTime : Float = 0.;
	var lastSentBytes = 0;
	var markHead : NetworkSerializable;
	var registerHead : NetworkSerializable;
	var ctx : NetworkSerializer;
	var pendingClients : Array<NetworkClient>;
	var logger : String -> Void;
	var stats : NetworkStats;
	var rpcUID = Std.random(0x1000000);
	var rpcWaits = new Map<Int,NetworkSerializer->Void>();
	var targetClient : NetworkClient;
	var rpcClientValue : NetworkClient;
	var aliveEvents : Array<Void->Void>;
	var rpcPosition : Int;
	public var clients : Array<NetworkClient>;
	public var self(default,null) : NetworkClient;
	public var lateRegistration = false;

	public function new() {
		current = this;
		isAuth = true;
		self = new NetworkClient(this);
		clients = [];
		aliveEvents = [];
		pendingClients = [];
		resetState();
	}

	public function dispose() {
		if( current == this ) current = null;
	}

	public function isConnected(owner) {
		return resolveClient(owner) != null;
	}

	public function resolveClient(owner) {
		if( self.ownerObject == owner )
			return self;
		for( c in clients )
			if( c.ownerObject == owner )
				return c;
		return null;
	}

	public function resetState() {
		hxbit.Serializer.resetCounters();
		ctx = new NetworkSerializer(this);
		@:privateAccess ctx.newObjects = [];
		ctx.begin();
	}

	public function saveState() {
		var s = new hxbit.Serializer();
		s.beginSave();
		var refs = [for( r in ctx.refs ) r];
		refs.sort(sortByUID);
		for( r in refs )
			if( !s.refs.exists(r.__uid) )
				s.addAnyRef(r);
		s.addAnyRef(null);
		return s.endSave();
	}

	public function loadSave( bytes : haxe.io.Bytes ) {
		ctx.enableChecks = false;
		ctx.refs = new Map();
		@:privateAccess ctx.newObjects = [];
		ctx.beginLoad(bytes);
		while( true ) {
			var v = ctx.getAnyRef();
			if( v == null ) break;
		}
		ctx.endLoad();
		ctx.enableChecks = true;
	}

	function checkWrite( o : NetworkSerializable, vid : Int ) {
		if( !isAuth && !o.networkAllow(SetField,vid,self.ownerObject) ) {
			logError("Setting a property on a not allowed object", o.__uid);
			return false;
		}
		return true;
	}

	inline function checkSyncingProperty(b : Int) {
		if( isSyncingProperty == b ) {
			isSyncingProperty = -1;
			return false;
		}
		return true;
	}

	function mark(o:NetworkSerializable) {
		o.__next = markHead;
		markHead = o;
		return true;
	}

	function get_rpcClient() {
		return rpcClientValue == null ? self : rpcClientValue;
	}

	public dynamic function logError( msg : String, ?objectId : Int ) {
		throw msg + (objectId == null ? "":  "(" + objectId + ")");
	}

	public dynamic function onMessage( from : NetworkClient, msg : Dynamic ) {
	}

	public dynamic function onUnregister(o : hxbit.NetworkSerializable) {
	}

	function onCustom( from : NetworkClient, id : Int, ?data : haxe.io.Bytes ) {
	}

	public function sendMessage( msg : Dynamic, ?to : NetworkClient ) {
		flush();
		var prev = targetClient;
		targetClient = to;
		if( Std.isOfType(msg, haxe.io.Bytes) ) {
			ctx.addByte(BMSG);
			ctx.addBytes(msg);
		} else {
			ctx.addByte(MSG);
			ctx.addString(haxe.Serializer.run(msg));
		}
		if( checkEOM ) ctx.addByte(EOM);
		doSend();
		targetClient = prev;
	}

	function sendCustom( id : Int, ?data : haxe.io.Bytes, ?to : NetworkClient ) {
		flush();
		var prev = targetClient;
		targetClient = to;
		ctx.addByte(data == null ? CUSTOM : BCUSTOM);
		ctx.addInt(id);
		if( data != null ) ctx.addBytes(data);
		if( checkEOM ) ctx.addByte(EOM);
		doSend();
		targetClient = prev;
	}

	function setTargetOwner( owner : NetworkSerializable ) {
		if( !isAuth )
			return true;
		if( owner == null ) {
			doSend();
			targetClient = null;
			return true;
		}
		flush();
		targetClient = null;
		for( c in clients )
			if( c.ownerObject == owner ) {
				targetClient = c;
				break;
			}
		return targetClient != null; // owner not connected
	}

	function beginRPC(o:NetworkSerializable, id:Int, onResult:NetworkSerializer->Void) {
		flushProps();
		if( ctx.refs[o.__uid] == null )
			throw "Can't call RPC on an object not previously transferred";
		if( onResult != null ) {
			var id = rpcUID++;
			ctx.addByte(RPC_WITH_RESULT);
			ctx.addInt(id);
			rpcWaits.set(id, onResult);
		} else
			ctx.addByte(RPC);
		ctx.addInt(o.__uid);
		#if hl
		rpcPosition = @:privateAccess ctx.out.pos;
		#end
		ctx.addInt32(-1);
		ctx.addByte(id);
		if( logger != null )
			logger("RPC > " + o+"#"+o.__uid + " " + o.networkGetName(id,true));
		if( stats != null )
			stats.beginRPC(o, id);
		return ctx;
	}

	function endRPC() {
		#if hl
		@:privateAccess ctx.out.b.setI32(rpcPosition, ctx.out.pos - (rpcPosition + 5));
		if( stats != null )
			stats.endRPC(@:privateAccess ctx.out.pos - rpcPosition);
		#end
		if( checkEOM ) ctx.addByte(EOM);
	}

	function fullSync( c : NetworkClient ) {
		if( !pendingClients.remove(c) )
			return;
		flush();

		// unique client sequence number
		var seq = clients.length + 1;
		while( true ) {
			var found = false;
			for( c in clients )
				if( c.seqID == seq ) {
					found = true;
					break;
				}
			if( !found ) break;
			seq++;
		}
		if( seq > 0xFF ) throw "Out of sequence number";
		ctx.addByte(seq);
		c.seqID = seq;

		clients.push(c);

		var refs = ctx.refs;
		ctx.enableChecks = false;
		ctx.begin();
		ctx.addByte(FULLSYNC);
		ctx.addByte(c.seqID);
		ctx.addBytes(Serializer.getSignature());

		var objs = [for( o in refs ) if( o != null ) o];
		objs.sort(sortByUID);
		for( o in objs )
			ctx.addAnyRef(o);
		ctx.addAnyRef(null);
		if( checkEOM ) ctx.addByte(EOM);
		ctx.enableChecks = true;

		targetClient = c;
		doSend();
		targetClient = null;
	}

	public function defaultLogger( ?filter : String -> Bool ) {
		var t0 = haxe.Timer.stamp();
		setLogger(function(str) {
			if( filter != null && !filter(str) ) return;
			str = (isAuth ? "[S] " : "[C] ") + str;
			str = Std.int((haxe.Timer.stamp() - t0)*100)/100 + " " + str;
			#if	sys Sys.println(str); #else trace(str); #end
		});
	}

	public inline function addAliveEvent(f) {
		aliveEvents.push(f);
	}

	public function isAliveComplete() {
		return @:privateAccess ctx.newObjects.length == 0 && aliveEvents.length == 0;
	}

	static function sortByUID(o1:Serializable, o2:Serializable) {
		return o1.__uid - o2.__uid;
	}

	static function sortByUIDDesc(o1:Serializable, o2:Serializable) {
		return o2.__uid - o1.__uid;
	}

	public function makeAlive() {
		var objs = @:privateAccess ctx.newObjects;
		if( objs.length == 0 )
			return;
		objs.sort(sortByUIDDesc);
		for( o in objs ) {
			var n = #if haxe4 Std.downcast #else Std.instance #end (o, NetworkSerializable);
			if( n == null ) continue;
			n.__host = this;
		}
		while( true ) {
			var o = objs.pop();
			if( o == null ) break;
			var n = #if haxe4 Std.downcast #else Std.instance #end (o, NetworkSerializable);
			if( n == null ) continue;
			n.alive();
		}
		while( aliveEvents.length > 0 )
			aliveEvents.shift()();
	}

	public function setLogger( log : String -> Void ) {
		this.logger = log;
	}

	public function setStats( stats ) {
		this.stats = stats;
	}

	inline function dispatchClients( callb : NetworkClient -> Void ) {
		var old = targetClient;
		for( c in clients )
			callb(c);
		targetClient = old;
	}

	function register( o : NetworkSerializable ) {
		o.__host = this;
		var o2 = ctx.refs[o.__uid];
		if( o2 != null ) {
			if( o2 != (o:Serializable) ) logError("Register conflict between objects", o.__uid);
			return;
		}
		if( !isAuth && !o.networkAllow(Register,0,self.ownerObject) )
			throw "Can't register "+o+" without ownership";
		if( lateRegistration ) {
			if( registerHead == null ) {
				o.__next = o;
				registerHead = o;
			} else {
				o.__next = registerHead;
				registerHead = o;
			}
			return;
		}
		if( logger != null )
			logger("Register " + o + "#" + o.__uid);
		ctx.addByte(REG);
		ctx.addAnyRef(o);
		if( checkEOM ) ctx.addByte(EOM);
	}

	function unmark( o : NetworkSerializable ) {
		if( o.__next == null )
			return;
		var prev = null;
		var h = markHead;
		while( h != o ) {
			prev = h;
			h = h.__next;
		}
		if( prev == null )
			markHead = o.__next;
		else
			prev.__next = o.__next;
		o.__next = null;
	}

	function unregister( o : NetworkSerializable ) {
		if( o.__host == null )
			return;
		if( !isAuth && !o.networkAllow(Unregister,0,self.ownerObject) )
			throw "Can't unregister "+o+" without ownership";
		if( lateRegistration ) {
			// was it pending register ?
			var h = registerHead, p : hxbit.NetworkSerializable = null;
			while( p != h ) {
				if( h == o ) {
					var n = o.__next;
					if( p == null )
						registerHead = n == o ? null : n;
					else
						p.__next = n == o ? p : n;
					o.__host = null;
					o.__next = null;
					o.__bits1 = 0;
					o.__bits2 = 0;
					return;
				}
				p = h;
				h = h.__next;
			}
		}
		flushProps(); // send changes
		o.__host = null;
		o.__bits1 = 0;
		o.__bits2 = 0;
		unmark(o);
		if( logger != null )
			logger("Unregister " + o+"#"+o.__uid);
		ctx.addByte(UNREG);
		ctx.addInt(o.__uid);
		if( checkEOM ) ctx.addByte(EOM);
		ctx.refs.remove(o.__uid);
	}

	function doSend() {
		var bytes;
		@:privateAccess {
			bytes = ctx.out.getBytes();
			ctx.out = new haxe.io.BytesBuffer();
		}
		send(bytes);
	}

	function send( bytes : haxe.io.Bytes ) {
		if( targetClient != null ) {
			totalSentBytes += (bytes.length + perPacketBytes);
			targetClient.send(bytes);
		}
		else {
			totalSentBytes += (bytes.length + perPacketBytes) * clients.length;
			if( clients.length == 0 ) totalSentBytes += bytes.length + perPacketBytes; // still count for statistics
			for( c in clients )
				c.send(bytes);
		}
	}

	function flushProps() {
		while( registerHead != null ) {
			var o = registerHead;
			registerHead = o.__next;
			o.__next = null;
			o.__bits1 = 0;
			o.__bits2 = 0;

			var o2 = ctx.refs[o.__uid];
			if( o2 != null ) {
				if( o2 != (o:Serializable) ) logError("Register conflict between objects", o.__uid);
				continue;
			}
			if( logger != null )
				logger("Register " + o + "#" + o.__uid);
			ctx.addByte(REG);
			ctx.addAnyRef(o);
			if( checkEOM ) ctx.addByte(EOM);
		}
		var o = markHead;
		while( o != null ) {
			if( (o.__bits1|o.__bits2) != 0 ) {
				if( logger != null ) {
					var props = [];
					var i = 0;
					while( 1 << i <= o.__bits1 ) {
						if( o.__bits1 & (1 << i) != 0 )
							props.push(o.networkGetName(i));
						i++;
					}
					i = 0;
					while( 1 << i <= o.__bits2 ) {
						if( o.__bits2 & (1 << i) != 0 )
							props.push(o.networkGetName(i+30));
						i++;
					}
					logger("SYNC > " + o + "#" + o.__uid + " " + props.join("|"));
				}
				if( stats != null )
					stats.sync(o);
				ctx.addByte(SYNC);
				ctx.addInt(o.__uid);
				o.networkFlush(ctx);
				if( checkEOM ) ctx.addByte(EOM);
			}
			var n = o.__next;
			o.__next = null;
			o = n;
		}
		markHead = null;
	}

	function isCustomMessage( bytes : haxe.io.Bytes, id : Int, pos = 0 ) {
		if( bytes.length - pos < 2 )
			return false;
		ctx.setInput(bytes, pos);
		var k = ctx.getByte();
		if( k != CUSTOM && k != BCUSTOM )
			return false;
		return ctx.getInt() == id;
	}

	public function flush() {
		flushProps();
		if( @:privateAccess ctx.out.length > 0 ) doSend();
		// update sendRate
		var now = haxe.Timer.stamp();
		var dt = now - lastSentTime;
		if( dt < 1 )
			return;
		var db = totalSentBytes - lastSentBytes;
		var rate = db / dt;
		if( sendRate == 0 || rate == 0 || rate / sendRate > 3 || sendRate / rate > 3 )
			sendRate = rate;
		else
			sendRate = sendRate * 0.8 + rate * 0.2; // smooth
		lastSentTime = now;
		lastSentBytes = totalSentBytes;

		// check for unresponsive clients (nothing received from them)
		for( c in clients )
			if( now - c.lastMessage > CLIENT_TIMEOUT )
				c.stop();
	}

	static function enableReplication( o : NetworkSerializable, b : Bool ) {
		if( b ) {
			if( o.__host != null ) return;
			if( current == null ) throw "No NetworkHost defined";
			current.register(o);
		} else {
			if( o.__host == null ) return;
			o.__host.unregister(o);
		}
	}


}