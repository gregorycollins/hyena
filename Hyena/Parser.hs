{-# LANGUAGE Rank2Types #-}

------------------------------------------------------------------------
-- |
-- Module      :  Hyena.Parser
-- Copyright   :  (c) Johan Tibell 2008
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  johan.tibell@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- A resumable LL(1) parser combinator library for 'ByteString's.
--
------------------------------------------------------------------------

module Hyena.Parser
    (
      -- * The Parser type
      Parser,
      Result(..),
      runParser,

      -- * Primitive parsers
      satisfies,
      byte,
      bytes,

      module Control.Applicative
    ) where

import Control.Applicative
import qualified Data.ByteString as S
import qualified Data.ByteString.Internal as S
import Data.Int (Int64)
import Data.Word (Word8)
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (peekByteOff)
import Prelude hiding (fail, rem, succ)
import Text.Show.Functions ()

-- ---------------------------------------------------------------------
-- The Parser type

-- | The parse state.
data S r = S
    {-# UNPACK #-} !S.ByteString
    {-# UNPACK #-} !Int64
    {-# UNPACK #-} !Bool
    {-# UNPACK #-} !(S r -> Result r)
         deriving Show

-- | Set the failure continuation.
setFail :: S r -> (S r -> Result r) -> S r
setFail (S bs pos eof _) = S bs pos eof
{-# INLINE setFail #-}

-- | A parse either succeeds, fails or returns a suspension with which
-- the parsing can be resumed.
data Result a = Finished a S.ByteString
              -- ^ Parsing succeeded and produced a value of type
              -- @a@. The returned 'S.ByteString' is the remaining
              -- unconsumed input.
              | Failed Int64
              -- ^ Parsing failed at the given position. Either
              -- because the parser didn't match the input or because
              -- an unexpected end of input was reached during
              -- parsing.
              | Partial (Maybe S.ByteString -> Result a)
              -- ^ The parsing needs more input to continue. Pass in
              -- @Just input@ to continue parsing and @Nothing@ to
              -- signal end of input. If @Nothing@ is passed the
              -- 'Result' is either 'Finished' or 'Failed'.
                deriving Show

-- | A parser takes a parse state, a success continuation and returns
-- a 'Result'.
newtype Parser a = Parser
    { unParser :: forall r. S r -> (a -> S r -> Result r) -> Result r }

-- ---------------------------------------------------------------------
-- Instances

instance Functor Parser where
    fmap f p = Parser $ \s succ -> unParser p s (succ . f)
    {-# INLINE fmap #-}

instance Applicative Parser where
    pure a = Parser $ \s succ -> succ a s
    {-# INLINE pure #-}

    p <*> p' = Parser $ \s succ ->
               let succ' f s' = unParser p' s' (succ . f)
               in unParser p s succ'
    {-# INLINE (<*>) #-}

instance Alternative Parser where
    empty = Parser $ \s@(S _ _ _ fail) _ -> fail s
    {-# INLINE empty #-}

    p <|> p' = Parser $ \s@(S _ _ _ fail) succ ->
               let fail' s' = unParser p' (setFail s' fail) succ
               in unParser p (setFail s fail') succ
    {-# INLINE (<|>) #-}

-- ---------------------------------------------------------------------
-- Running a parser

initState :: S.ByteString -> S r
initState bs = S bs 0 False failed
{-# INLINE initState #-}

-- | This is the final continuation that turns a successful parse into
-- a 'Result'.
finished :: a -> S r -> Result a
finished v (S bs _ _ _) = Finished v bs

-- | This is the final continuation that turns an unsuccessful parse
-- into a 'Result'.
failed :: S r -> Result a
failed (S _ pos _ _) = Failed pos

-- | TODO: Write documentation.
runParser :: Parser a -> S.ByteString -> Result a
runParser p bs = unParser p (initState bs) finished

-- ---------------------------------------------------------------------
-- Primitive parsers

-- | The parser @satisfies p@ succeeds for any byte for which the
-- supplied function @p@ returns 'True'.  Returns the byte that is
-- actually parsed.
satisfies :: (Word8 -> Bool) -> Parser Word8
satisfies p =
    Parser $ \s@(S bs pos eof fail) succ ->
        case S.uncons bs of
          Just (b, bs') -> if p b
                           then succ b (S bs' (pos + 1) eof failed)
                           else fail s
          Nothing       -> if eof
                           then fail s
                           else Partial $ \x ->
                               case x of
                                 Just bs' -> retry (S bs' pos eof fail)
                                 Nothing  -> fail (S bs pos True fail)
            where retry s' = unParser (satisfies p) s' succ

-- | @byte b@ parses a single byte @b@.  Returns the parsed byte
-- (i.e. @b@).
byte :: Word8 -> Parser Word8
byte b = satisfies (== b)

-- TODO: Check when we can let go of the failure continuation.

-- | @bytes bs@ parses a sequence of bytes @bs@.  Returns the parsed
-- bytes (i.e. @bs@).
bytes :: S.ByteString -> Parser S.ByteString
bytes bs =
    Parser $ \(S bs' pos eof fail) succ ->
        let go rem inp
                | len == remLen =
                    succ bs (S (S.drop len inp) newPos eof failed)
                | len < remLen && inpLen >= remLen =
                    fail (S (S.drop len inp) newPos eof fail)
                | otherwise =
                    Partial $ \x ->
                        case x of
                          Just bs'' -> go (S.drop len rem) bs''
                          Nothing   -> fail (S S.empty newPos True fail)
                where
                  len    = commonPrefixLen rem inp
                  remLen = S.length rem
                  newPos = pos + fromIntegral len
                  inpLen = S.length inp
        in go bs bs'

-- ---------------------------------------------------------------------
-- Internal utilities

-- | /O(n)/ @commonPrefixLen xs ys@ returns the length of the longest
-- common prefix of @xs@ and @ys@.
commonPrefixLen :: S.ByteString -> S.ByteString -> Int
commonPrefixLen (S.PS fp1 off1 len1) (S.PS fp2 off2 len2) =
    S.inlinePerformIO $
     withForeignPtr fp1 $ \p1 ->
         withForeignPtr fp2 $ \p2 ->
             lcp (p1 `plusPtr` off1) (p2 `plusPtr` off2) 0 len1 len2

lcp :: Ptr Word8 -> Ptr Word8 -> Int -> Int -> Int-> IO Int
lcp p1 p2 n len1 len2
    | n == len1 = return len1
    | n == len2 = return len2
    | otherwise = do
        a <- peekByteOff p1 n :: IO Word8
        b <- peekByteOff p2 n
        if a == b then lcp p1 p2 (n + 1) len1 len2 else return n
