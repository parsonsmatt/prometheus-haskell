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
