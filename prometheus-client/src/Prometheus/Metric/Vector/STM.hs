{-# LANGUAGE BangPatterns #-}

-- | This is a variant of the "Prometheus.Metric.Vector" that uses
-- @stm-containers@ "StmContainers.Map" instead of an @'IORef' ('Data.Map.Map' k v)@.
module Prometheus.Metric.Vector.STM (
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

import Data.Hashable
import Control.Concurrent.STM (atomically)
import System.IO.Unsafe (unsafeInterleaveIO)
import Control.DeepSeq
import qualified Data.Text as T
import qualified StmContainers.Map as Map
import qualified ListT
import qualified Focus


data VectorState l m = VectorState
    { vectorStateMetric :: !(Metric m)
    , vectorStateMetricMap :: !(Map.Map l (MetricImpl m))
    }

newtype Vector l m = MkVector (VectorState l m)

instance NFData (Vector l m) where
  rnf (MkVector ioref) = seq ioref ()

-- | Creates a new vector of metrics given a label.
vector :: Label l => l -> Metric m -> Metric (Vector l m)
vector labels gen = Metric $ do
    ms <- Map.newIO
    let vectorState = checkLabelKeys labels $ VectorState gen ms
    return $! MetricImpl (MkVector vectorState) (collectVector labels ms)

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
collectVector :: Label l => l -> Map.Map l (MetricImpl m) -> IO [SampleGroup]
collectVector keys metricMap = do
    assocs <- ListT.toList $ Map.listTNonAtomic metricMap
    joinSamples <$> concat <$> mapM collectInner assocs
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

getAssocs :: Map.Map k v -> IO [(k, v)]
getAssocs = ListT.toList . Map.listTNonAtomic

getVectorWith :: Vector label metric
              -> (metric -> IO a)
              -> IO [(label, a)]
getVectorWith (MkVector (VectorState _ metricMap)) f = do
    traverse (traverse (f . metricImplState)) =<< getAssocs metricMap

-- | Given a label, applies an operation to the corresponding metric in the
-- vector.
withLabel :: (Hashable label, Label label, MonadMonitor m)
          => Vector label metric
          -> label
          -> (metric -> IO ())
          -> m ()
withLabel (MkVector (VectorState gen metricMap)) label f = doIO $ do
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
    metric' <- atomically $ do
        Map.focus (Focus.alter (\maybeMetric ->
            case maybeMetric of
                Nothing ->
                    Just newMetric
                Just metric ->
                    Just metric
                ) *> Focus.lookupWithDefault newMetric)
            label
            metricMap

    f (metricImplState metric')

-- | Removes a label from a vector.
removeLabel :: (Hashable label, Label label, MonadMonitor m)
            => Vector label metric -> label -> m ()
removeLabel (MkVector (VectorState _ metricMap)) label =
    doIO $ atomically $ Map.delete label metricMap

-- | Removes all labels from a vector.
clearLabels :: (Label label, MonadMonitor m)
            => Vector label metric -> m ()
clearLabels (MkVector (VectorState _ metricMap)) =
    doIO $ atomically $ Map.reset metricMap
