{-# LANGUAGE BangPatterns #-}

module Prometheus.Metric.Vector (
    Vector (..)
,   vector
,   withLabel
,   removeLabel
,   clearLabels
,   getVectorWith
) where

import Prometheus.Label
import Prometheus.Metric
import Prometheus.MonadMonitor

import System.IO.Unsafe (unsafeInterleaveIO)
import Control.Applicative ((<$>))
import Control.DeepSeq
import qualified Data.Atomics as Atomics
import qualified Data.IORef as IORef
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Traversable (forM)


data VectorState l m = VectorState
    { vectorStateMetric :: !(Metric m)
    , vectorStateMetricMap :: !(Map.Map l (MetricImpl m))
    }

data Vector l m = MkVector (IORef.IORef (VectorState l m))

instance NFData (Vector l m) where
  rnf (MkVector ioref) = seq ioref ()

-- | Creates a new vector of metrics given a label.
vector :: Label l => l -> Metric m -> Metric (Vector l m)
vector labels gen = Metric $ do
    ioref <- checkLabelKeys labels $ IORef.newIORef $ VectorState gen Map.empty
    return $ MetricImpl (MkVector ioref) (collectVector labels ioref)

checkLabelKeys :: Label l => l -> a -> a
checkLabelKeys keys r = foldl check r $ map (T.unpack . labelKey) $ unLabelPairs $ labelPairs keys keys
    where
        check _ "instance" = error "The label 'instance' is reserved."
        check _ "job"      = error "The label 'job' is reserved."
        check _ "quantile" = error "The label 'quantile' is reserved."
        check a (k:ey)
            | validStart k && all validRest ey = a
            | otherwise = error $ "The label '" ++ (k:ey) ++ "' is not valid."
        check _ []         = error "Empty labels are not allowed."

        validStart c =  ('a' <= c && c <= 'z')
                     || ('A' <= c && c <= 'Z')
                     || c == '_'

        validRest c =  ('a' <= c && c <= 'z')
                    || ('A' <= c && c <= 'Z')
                    || ('0' <= c && c <= '9')
                    || c == '_'

-- TODO(will): This currently makes the assumption that all the types and info
-- for all sample groups returned by a metric's collect method will be the same.
-- It is not clear that this will always be a valid assumption.
collectVector :: Label l => l -> IORef.IORef (VectorState l m) -> IO [SampleGroup]
collectVector keys ioref = do
    VectorState _ metricMap <- IORef.readIORef ioref
    joinSamples <$> concat <$> mapM collectInner (Map.assocs metricMap)
    where
        collectInner (labels, (MetricImpl _metric sampleGroups)) =
            map (adjustSamples labels) <$> sampleGroups

        adjustSamples labels (SampleGroup info ty samples) =
            SampleGroup info ty (map (prependLabels labels) samples)

        prependLabels l (Sample name labels value) =
            Sample name (labelPairs keys l <> labels) value

        joinSamples []                      = []
        joinSamples s@(SampleGroup i t _:_) = [SampleGroup i t (extract s)]

        extract [] = []
        extract (SampleGroup _ _ s:xs) = s ++ extract xs

getVectorWith :: Vector label metric
              -> (metric -> IO a)
              -> IO [(label, a)]
getVectorWith (MkVector valueTVar) f = do
    VectorState _ metricMap <- IORef.readIORef valueTVar
    Map.assocs <$> forM metricMap (f . metricImplState)

-- | Given a label, applies an operation to the corresponding metric in the
-- vector.
withLabel :: (Label label, MonadMonitor m)
          => Vector label metric
          -> label
          -> (metric -> IO ())
          -> m ()
withLabel (MkVector ioref) label f = doIO $ do
    VectorState gen _ <- IORef.readIORef ioref
    -- NOTE: `unsafeInterleaveIO` is used here because we are doing an
    -- `atomicModifyIORef`. We only conditionally use the `newMetric` if
    -- the `Map` does not already *have* a metric.
    --
    -- Using `unsafeInterleaveIO` will run `gen` lazily, only when the
    -- `newMetric` is actually demanded. Since we are using `Map.alterF`,
    -- this will only occur if we are actually placing a new metric in the
    -- map.
    --
    -- Alternative: MVar
    --
    -- An alternative to this would be using an MVar. The `modifyMVar_`
    -- function has signature `MVar a -> (a -> IO a) -> IO ()`, and would
    -- allow us to avoid unsafe IO. One con of this is that consumers would
    -- be blocked and waiting on the MVar to read.
    --
    -- Alternative: stm-containers
    --
    -- An `IORef (Map k v)` is a bit of a smell - you must take the entire
    -- `Map` in order to do any operation, harming concurrent access.
    -- Instead, an `StmContainers.Map` would allow threads to access
    -- a single key in `STM`, and only cause transaction aborts or retries
    -- if the
    newMetric <- unsafeInterleaveIO $ construct gen
    MetricImpl metric _newVectorState <- IORef.atomicModifyIORef' ioref $ \(VectorState _ metricMap) ->
        let (metricToReturn, updatedMap) =
                Map.alterF
                    (\maybeMetric -> case maybeMetric of
                        Nothing ->
                            (newMetric, Just newMetric)
                        Just metric ->
                            (metric, Just metric)
                    )
                    label
                    metricMap
        in
            (VectorState gen updatedMap, metricToReturn)

    f metric

-- | Removes a label from a vector.
removeLabel :: (Label label, MonadMonitor m)
            => Vector label metric -> label -> m ()
removeLabel (MkVector valueTVar) label =
    doIO $ IORef.atomicModifyIORef' valueTVar (\a -> (f a, ()))
    where f (VectorState desc metricMap) = VectorState desc (Map.delete label metricMap)

-- | Removes all labels from a vector.
clearLabels :: (Label label, MonadMonitor m)
            => Vector label metric -> m ()
clearLabels (MkVector valueTVar) =
    doIO $ IORef.atomicModifyIORef' valueTVar (\a -> (f a, ()))
    where f (VectorState desc _) = VectorState desc Map.empty
