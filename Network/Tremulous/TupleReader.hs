module Network.Tremulous.TupleReader where
import Control.Monad.State.Strict
import Network.Tremulous.StrictMaybe
import Prelude (Eq(..), otherwise, ($), (.), id)

type TupleReader k v a = StateT [(k, v)] Maybe a

tupleReader :: TupleReader k v a -> [(k, v)] -> Maybe a
tupleReader = evalStateT

lookupDelete :: (Eq k) => k -> [(k, v)] -> (Maybe v, [(k, v)])
lookupDelete key = roll where
    roll []         = (Nothing, [])
    roll (x@(a, b):xs)
        | key == a  = (Just b, xs)
        | otherwise = let ~(may, xs') = roll xs in (may, x:xs')

require :: Eq k => k -> TupleReader k v v
require key = option key >>= lift

requireWith :: Eq k => (v -> Maybe a) -> k -> TupleReader k v a
requireWith f key = do
    e <- option key
    lift $ f =<< e

optionWith :: Eq k => (v -> Maybe a) -> k -> TupleReader k v (Maybe a)
optionWith f key = do
    e <- option key
    return (f =<< e)


option :: Eq k => k -> TupleReader k v (Maybe v)
option key = do
    s <- get
    let (e, s') = lookupDelete key s
    put s'
    return e
