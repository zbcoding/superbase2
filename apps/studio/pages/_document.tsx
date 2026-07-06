import Document, { Head, Html, Main, NextScript } from 'next/document'

import { BootTimeoutFallback } from '@/components/ui/BootTimeoutFallback/BootTimeoutFallback'
import { inter, manrope, sourceCodePro } from '@/fonts'

class MyDocument extends Document {
  render() {
    return (
      <Html lang="en">
        <Head />
        <body className={`${inter.variable} ${manrope.variable} ${sourceCodePro.variable}`}>
          <BootTimeoutFallback />
          <Main />
          <NextScript />
        </body>
      </Html>
    )
  }
}

export default MyDocument
