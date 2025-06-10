# Investigating Memory Use in `prometheus-client`

We're runnig into problems with unexpectedly high memory use in `prometheus-client`, so I've been investigating improving the behavior.

Specifically, we're notificing a significant increase in the amount of time and memory allocated while calling `exportMetricsToText`.
Every time we call the endpoint, more and more memory is used to render the response.
There are two reasonable possibilities for this:

1. The `exportMetricsToText` is producing a significantly larger `Text` value, which naturally requires significantly more memory.
2. The metrics themselves are somehow holding on to excessive memory or thunks.

Diagnosing this in our application is difficult - our profiling build is currently broken.
So I'm currently just looking at the code and correcting known smells.

## `LabelPairs`

The `LabelPairs` type was a `[(Text, Text)]`.
Lists and tuples are both known sources of potential laziness issues.
As a first pass, I replaced the type with a `newtype` so I could control the API for accessing and adding entries.
Then I replaced the tuple with a `data LabelPair = LabelPair { labelKey :: !Text, labelValue :: !Text }`.
This should prevent thunk accumulation for labels, and the concrete type may enable further memory improvement from GHC.

The fields on `Sample` are made strict, as well.
This should prevent thunk accumulation on the `Text` and `ByteString`, but a lazy `LabelPairs` is still possible.

Additionally, the `labelPairs` function now uses bang patterns on each `Text` in the tuple.
Since this is the whole of the interface for constructing a `LabelPair`, this should prevent any thunk accumulation on labels.

## `MetricImpl`

A `Metric` had a field `construct :: IO (s, IO [SampleGroup])`.
To avoid tuple, we introduce `MetricImpl s` which uses bang patterns on the fields.

In practice, the `MetricImpl s` is almost always instantiated to a reference type, and evaluating a reference doesn't do much to help.
I did find the clarity in names helpful.

## `VectorState`

A `Prometheus.Metric.Vector` previously was defined as:

```haskell
type VectorState l m = (Metric m, Map.Map l (m, IO [SampleGroup]))
```

This `VectorSTate` was being stored in an `IORef`.
While the operation was evaluating the `VectorState` to WHNF, this only evaluated the tuple constructor, leaving the `Metric` and `Map.Map` unevaluated.
The `Map` is from `Data.Map.Strict`, which means that the values are evaluated to WHNF.
Methods from that module evaluate the structure of the `Map`, but polymorphic methods (ie `Functor`, `Traversable`) *do not*.

We can reduce the possibility of memory leaks here by replacing this with a record, bang patterns, and omitting the tuple for the `MetricImpl` type.


