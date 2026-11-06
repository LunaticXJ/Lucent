import AppKit
import ImageIO
typealias LucentPlatformImage = NSImage
@main struct Check {
    @MainActor static func main() async {
        for (w,h) in [(4000,6000),(6000,3375),(1200,800),(800,3200)] {
            let context = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(gray:0.5,alpha:1)); context.fill(CGRect(x:0,y:0,width:w,height:h))
            let data = NSMutableData()
            let writer = CGImageDestinationCreateWithData(data,"public.jpeg" as CFString,1,nil)!
            CGImageDestinationAddImage(writer,context.makeImage()!,nil);CGImageDestinationFinalize(writer)
            for budget in [8_000_000,2_000_000] {
                let key = "fixture-\(w)-\(h)"
                async let first = ArtworkImageDecoder.image(data:data as Data,key:key,maximumPixelSize:4096,targetPixelSize:CGSize(width:1320,height:2180),maximumDecodedPixels:budget)
                async let second = ArtworkImageDecoder.image(data:data as Data,key:key,maximumPixelSize:4096,targetPixelSize:CGSize(width:1320,height:2180),maximumDecodedPixels:budget)
                let (a,b) = await(first,second)
                precondition(a != nil && a === b,"cache must preserve decoded identity")
                let cg = a!.cgImage(forProposedRect:nil,context:nil,hints:nil)!
                precondition(cg.width*cg.height <= budget + 4096,"pixel budget exceeded")
                precondition(max(cg.width,cg.height)<=4096,"long edge exceeded")
                precondition(cg.width<=w && cg.height<=h,"must not upscale")
                print("PASS \(w)x\(h), budget \(budget): \(cg.width)x\(cg.height)")
            }
        }
    }
}
