module Swipe exposing
    ( onMove, onEnd, onStart, onEndWithOptions
    , Gesture, Event, blanco, record
    , Position, locate, deltaX, deltaY, isTap, isUpSwipe, isDownSwipe, isLeftSwipe, isRightSwipe
    )

{-| Early stages of gesture recognition for touch-events.

This is intended to be used in qualified form.


# Hooking it up

In your model:

    { gesture = Swipe.Gesture }

In your init:

    { gesture = Swipe.blanco }

In your Msg:

    type Msg
        = Swipe Swipe.Event
        | SwipeEnd Swipe.Event

In your view:

    Html.div
        [ Swipe.onStart Swipe
        , Swipe.onMove Swipe
        , Swipe.onEnd SwipeEnd
        ]
        [ Html.text "Swipe me!" ]

In your update:

    Swipe touch ->
        { model | gesture = Swipe.record touch model.gesture }

    SwipeEnd touch ->
        let
            gesture : Swipe.Gesture
            gesture =
                Swipe.record touch model.gesture

            -- use inspection functions like `isTap` and `isLeftSwipe`
        in
        { model | gesture = Swipe.blanco }


# Events stuff

@docs onMove, onEnd, onStart, onEndWithOptions


# Keep some state around

@docs Gesture, Event, blanco, record


# Get yourself some info

@docs Position, locate, deltaX, deltaY, isTap, isUpSwipe, isDownSwipe, isLeftSwipe, isRightSwipe

-}

import Html
import Html.Events exposing (custom, on)
import Json.Decode as Json exposing (Decoder)


{-| Checks if a given gesture is actually a (single) tap
-}
isTap : Gesture -> Bool
isTap gesture =
    case gesture of
        EndTap _ ->
            True

        _ ->
            False


{-| For a finished move, checks how much you move horizontally, from start to
finish.
-}
deltaX : Gesture -> Maybe Float
deltaX gesture =
    case gesture of
        EndGesture { from, to } ->
            Just (to.x - from.x)

        _ ->
            Nothing


{-| For a finished move, checks how much you move vertically, from start to
finish.
-}
deltaY : Gesture -> Maybe Float
deltaY gesture =
    case gesture of
        EndGesture { from, to } ->
            Just (to.y - from.y)

        _ ->
            Nothing


{-| Is this gesture finished and did we move more than `sensitivity`
(difference between `touchstart` and `touchend` in px) to the right?
-}
isRightSwipe : Float -> Gesture -> Bool
isRightSwipe sensitivity =
    isSwipeType deltaX (\dX -> dX >= sensitivity)


{-| Is this gesture finished and did we move more than `sensitivity`
(difference between `touchstart` and `touchend` in px) to the left?
-}
isLeftSwipe : Float -> Gesture -> Bool
isLeftSwipe sensitivity =
    isSwipeType deltaX (\dX -> dX <= -sensitivity)


{-| Is this gesture finished and did we move more than `sensitivity`
(difference between `touchstart` and `touchend` in px) to the bottom?
-}
isDownSwipe : Float -> Gesture -> Bool
isDownSwipe sensitivity =
    isSwipeType deltaY (\dY -> dY >= sensitivity)


{-| Is this gesture finished and did we move more than `sensitivity`
(difference between `touchstart` and `touchend` in px) to the top?
-}
isUpSwipe : Float -> Gesture -> Bool
isUpSwipe sensitivity =
    isSwipeType deltaY (\dY -> dY <= -sensitivity)


isSwipeType : (Gesture -> Maybe Float) -> (Float -> Bool) -> Gesture -> Bool
isSwipeType delta predicate =
    delta >> Maybe.map predicate >> Maybe.withDefault False


{-| A position, similar to the one in the `elm-lang/mouse` package.
-}
type alias Position =
    { x : Float, y : Float }


type alias Trail =
    { from : Position, through : List Position, to : Position }


{-| A `Gesture`! You'll want to keep one of these around in your model and
update it whenever applicable.
-}
type Gesture
    = None
    | Started Position
    | Moved Trail
    | EndGesture Trail
    | EndTap Position


{-| A single `Swipe.Event`. Gestures are made up of these, internally.
-}
type Event
    = Touch EventType Position


{-| Useful if you want to know the current position during a stream of events.
-}
locate : Event -> Position
locate (Touch _ position) =
    position


type EventType
    = Start
    | Move
    | End


{-| Get yourself a blanco gesture, as if no touches have happened at all.

After a touchend event, you'll probably want to reset to this, too.

-}
blanco : Gesture
blanco =
    None


addToTrail : Position -> Trail -> Trail
addToTrail coordinate { from, to, through } =
    { from = from, through = to :: through, to = coordinate }


{-| Our cute little `update`-like function!
-}
record : Event -> Gesture -> Gesture
record (Touch eventType coordinate) gesture =
    case ( eventType, gesture ) of
        ( Start, _ ) ->
            Started coordinate

        ( Move, Started prev ) ->
            Moved { from = prev, through = [], to = coordinate }

        ( Move, Moved trail ) ->
            addToTrail coordinate trail |> Moved

        ( Move, _ ) ->
            Started coordinate

        ( End, Moved trail ) ->
            addToTrail coordinate trail |> EndGesture

        ( End, _ ) ->
            EndTap coordinate


decodeTouch : String -> (Position -> msg) -> Decoder msg
decodeTouch fieldName tagger =
    Json.map2 Position
        (Json.field "clientX" Json.float)
        (Json.field "clientY" Json.float)
        |> Json.at [ fieldName, "0" ]
        |> Json.map tagger


decodeTouchWithOptions : String -> { stopPropagation : Bool, preventDefault : Bool } -> (Position -> msg) -> Decoder { message : msg, preventDefault : Bool, stopPropagation : Bool }
decodeTouchWithOptions fieldName options tagger =
    Json.map2 (\x y -> Position x y)
        (Json.field "clientX" Json.float)
        (Json.field "clientY" Json.float)
        |> Json.at [ fieldName, "0" ]
        |> Json.map (\p -> { message = tagger p, preventDefault = options.preventDefault, stopPropagation = options.stopPropagation })


{-| Record the start of a touch gesture.
-}
onStart : (Event -> msg) -> Html.Attribute msg
onStart tagger =
    on "touchstart" <| decodeTouch "touches" (Touch Start >> tagger)


{-| Record an ongoing touch gesture.
-}
onMove : (Event -> msg) -> Html.Attribute msg
onMove tagger =
    on "touchmove" <| decodeTouch "changedTouches" (Touch Move >> tagger)


{-| Record the end of a touch gesture.

**Note**: This sets `preventDefault = True` to avoid double events from occuring
when the same DOM node also has an `onClick` attribute. Using `preventDefault`
means that if a `touchend` event happens, the `onClick` handler won't fire.

If you have a case where you need to support a regular `onClick` event nested in
a node that has `onEnd` on it (for example; a container with swipe support,
which contains a button from an external package), please see `onEndWithOptions`.

-}
onEnd : (Event -> msg) -> Html.Attribute msg
onEnd =
    onEndWithOptions { stopPropagation = False, preventDefault = True }


{-| Record the end of a touch gesture with options.
-}
onEndWithOptions : { stopPropagation : Bool, preventDefault : Bool } -> (Event -> msg) -> Html.Attribute msg
onEndWithOptions options tagger =
    custom "touchend" <|
        decodeTouchWithOptions "changedTouches" options (Touch End >> tagger)
