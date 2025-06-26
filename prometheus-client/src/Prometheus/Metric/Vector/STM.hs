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
    -- NOTE: `unsafeInterleaveIO` will cause `construct gen` to be executed
    -- and evalauted when `newMetric` is demanded. We will only demand
    -- `newMetric` in the case that a `Metric` does not already exist in
    -- the map. This does mean that an IO action will be performed inside
    -- of an STM transaction. However, due to the nature of
    -- `unsafeInterleaveIO`, the resulting `newMetric` will be cached and
    -- reused, so the IO action will not be performed multiple times, even
    -- if the transaction is invalided and calls `retry`.
    --
    -- All instances of `Metric` currently do not perform side-effecting IO
    -- beyond allocating mutable references. As such, this should be safe.
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
