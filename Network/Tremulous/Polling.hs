module Network.Tremulous.Polling (
	pollMasters
	, pollOne
) where
import Prelude hiding (all, concat, mapM_, elem, sequence_, concatMap, catch)

import Control.Monad hiding (mapM_, sequence_)
import Control.Concurrent (forkIO, threadDelay, killThread)
import Control.Concurrent.MVar.Strict
import Control.Applicative
import Control.Exception

import Data.Foldable
import Data.Set (Set)
import qualified Data.Set as S
import Data.Map (Map)
import qualified Data.Map as M
import Data.String
import Data.ByteString.Char8 (ByteString, append, pack)

import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString
import Network.Tremulous.Protocol
import Network.Tremulous.ByteStringUtils as B
import Network.Tremulous.Scheduler

data QType = QMaster !Int !Int | QGame !Int | QJustWait

data Queue = Queue !SockAddr !Integer !Int !QType

mtu :: Int
mtu = 1500

getStatus :: IsString s => s
getStatus = "\xFF\xFF\xFF\xFFgetstatus"
getServers :: Int -> ByteString
getServers proto = "\xFF\xFF\xFF\xFFgetservers " `append` pack (show proto) `append` " empty full"

pollMasters :: Delay -> [MasterServer] -> IO ([GameServer], Int, Int, Set SockAddr)
pollMasters Delay{..} masterservers = do
	sock		<- socket AF_INET Datagram defaultProtocol
	bindSocket sock (SockAddrInet 0 0)
	
	-- server addresses recieved by master
	mstate		<- newMVar S.empty
	-- Servers that has responded
	tstate		<- newMVar S.empty
	
	-- When first packet was sent to server (removed on proper response)
	pingstate	<- newMVar (M.empty :: Map SockAddr Integer)

	let sf sched host qtype = case qtype of
		QGame n		-> do
			now <- getMicroTime
			pureModifyMVar pingstate $ M.insertWith' (\_ b -> b) host now
			sendTo sock (getStatus) host
			if (n > 0) then
				addScheduled sched (now + fromIntegral resendWait, host, QGame (n-1))
			else
				addScheduled sched (now + fromIntegral resendWait, host, QJustWait)
			
		QMaster n proto	-> do
			now <- getMicroTime
			sendTo sock (getServers proto) host
			if (n > 0) then
				addScheduled sched (now + (fromIntegral resendWait) `div` 2 , host, QMaster (n-1) proto)
			else
				addScheduled sched (now + fromIntegral resendWait, host, QJustWait)
				

		QJustWait -> return ()
		

	sched		<- newScheduler outBufferDelay sf (Just (sClose sock))
		
	addScheduledInstant sched $
		map (\(MasterServer proto host) -> (host, QMaster (resendTimes*4) proto)) masterservers

	let buildResponse = do
		packet <- ioMaybe $ recvFrom sock mtu
		case parsePacket (masterHost <$> masterservers) <$> packet of
			-- The master responded, great! Now lets send requests to the new servers
			Just (Master host x) -> do
				deleteScheduled sched host
				m <- takeMVar mstate
				let m' = S.union m x
				putMVar mstate m'
				let delta = S.difference x m
				when (S.size delta > 0) $ do
					addScheduledInstant sched $ map (,QGame resendTimes) (S.toList delta)
				
				buildResponse

			Just (Tremulous host x) -> do
				now <- getMicroTime
				t <- takeMVar tstate
				if S.member host t then do
					putMVar tstate t
					buildResponse
				else do
					deleteScheduled sched host
					ps	<- takeMVar pingstate
					start	<- return $! M.lookup host ps
					putMVar pingstate $ M.delete host ps
					putMVar tstate $ S.insert host t
					-- This also servers as protection against
					-- receiving responses for requests never sent
					case start of
						Nothing -> buildResponse
						Just a	-> do
							let gameping = fromInteger (now - a) `div` 1000
							( x{ gameping } : ) `liftM` buildResponse			
			Just Invalid -> buildResponse
			
			Nothing -> return []
			
	xs	<- buildResponse
	m	<- takeMVar mstate
	t	<- takeMVar tstate
	return $! (xs, S.size t, S.size m, t)
	

data Packet = Master !SockAddr !(Set SockAddr) | Tremulous !SockAddr !GameServer | Invalid

parsePacket :: [SockAddr] -> (ByteString, SockAddr) -> Packet
parsePacket masters (content, host) = case B.stripPrefix "\xFF\xFF\xFF\xFF" content of
	Just a	| Just x <- parseServer a			-> Tremulous host x
		| Just x <- parseMaster a, host `elem` masters	-> Master host x
	_							-> Invalid
	where
	parseMaster x = S.fromList . parseMasterServer <$> stripPrefix "getserversResponse" x
	parseServer x = parseGameServer host =<< stripPrefix "statusResponse" x



pollOne :: Delay -> SockAddr -> IO (Maybe GameServer)
pollOne Delay{..} sockaddr = do
	s <- socket AF_INET Datagram defaultProtocol
	catch (f s) (err s)
	where
	f sock = do
		connect sock sockaddr
		pid <- forkIO $ whileJust resendTimes $ \n -> do
			send sock getStatus
			threadDelay resendWait
			if n > 0 then
				return $ Just (n-1)
			else do
				sClose sock
				return Nothing
			
		start	<- getMicroTime
		poll	<- ioMaybe $ recv sock mtu
		killThread pid
		stop	<- getMicroTime
		let gameping = fromInteger (stop - start) `div` 1000
		return $ (\x -> x {gameping}) <$> 
			(parseGameServer sockaddr =<< isProper =<< poll)
	err sock (_::IOError) = sClose sock >> return Nothing
	isProper = stripPrefix "\xFF\xFF\xFF\xFFstatusResponse"

ioMaybe :: IO a -> IO (Maybe a)
ioMaybe f = catch (Just <$> f) (\(_ :: IOError) -> return Nothing)

whileJust :: Monad m => a -> (a -> m (Maybe a)) -> m ()
whileJust x f  = f x >>= \c -> case c of
	Just a	-> whileJust a f
	Nothing	-> return ()